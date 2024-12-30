-- Import necessary modules and functions
local api, vfn, uv, lsp = vim.api, vim.fn, vim.uv, vim.lsp
local protocol = require('vim.lsp.protocol')
local util = require('vim.lsp.util')
local ms = protocol.Methods

-- Create a unique highlight namespace and user-defined augroup
local zap_augroup = api.nvim_create_augroup('Zap', { clear = true })

-- Configuration defaults and variables
local pum_width = 33
local kind_format = nil
local debug_mode = false  -- Enable debug logging

-- State to prevent auto-completion redisplay and save cache
local context = {}
local request_state = {}

local additional_format_completion = function(entry) return entry end
local additional_score_handler = function(score, entry) return score end
local additional_sorting_handler = function(entries) return entries end

-- Logging function
local function log(...)
    if debug_mode then
        local args = {...}
        local msg = ""
        for i, arg in ipairs(args) do
            if type(arg) == "table" then
                msg = msg .. vim.inspect(arg)
            else
                msg = msg .. tostring(arg)
            end
            if i < #args then msg = msg .. " " end
        end
        print(string.format("[LSP Completion] %s", msg))
    end
end

-- Function: Initialize buffer-specific context
local function context_init(bufnr, id)
    log(string.format("Initializing context for buffer %d, client %d", bufnr, id))

    if not context[bufnr] then
        context[bufnr] = {
            clients = {},  -- Store client-specific data
            client_ids = {},  -- List of LSP client IDs
        }
    end

    -- Initialize per-client state
    context[bufnr].clients[id] = {
        timer = nil,
        cache = {},
        last_line = nil,
        last_prefix = nil,
        last_start_idx = nil,
        context_changed = false,
    }

    table.insert(context[bufnr].client_ids, id)
    log(string.format("Context initialized for buffer %d, client %d. Total clients: %d",
        bufnr, id, #context[bufnr].client_ids))
end

local function split(input_str, sep)
    local result = {}
    for str in input_str:gmatch("([^" .. sep .. "]+)") do
        table.insert(result, str)
    end
    return result
end

-- Function to clear all client caches
local function clear_all_client_caches(bufnr)
    if not context[bufnr] then return end
    log(string.format("Clearing all client caches for buffer %d", bufnr))

    for client_id, client_state in pairs(context[bufnr].clients) do
        client_state.cache = {}
        client_state.last_line = nil
        client_state.last_prefix = nil
        client_state.last_start_idx = nil
        log(string.format("Cleared cache for client %d", client_id))
    end
end

-- Function: Calculate match score for fuzzy matching.
-- Used internally by the sorting function.
local function calc_match_score(filter_text, prefix, cursor_pos, buffer_lines)
    -- Initialize base score
    local score = 0
    local is_abbrev = true  -- Temporary variable to determine if abbreviation match is possible
    local is_partial_abbrev = false  -- Temporary variable to determine if abbreviation match is possible

    -- Split by underscores and remove them. This gives us major parts.
    local underscore_split_parts = split(filter_text, "_")
    local parts = {}

    -- For each part, split further by capital letters if they exist
    for _, part in ipairs(underscore_split_parts) do
        if part:find("[A-Z]") then
            -- Use regex to split by capital letter boundaries for CamelCase words
            for camel_part in part:gmatch("[A-Z][a-z%d]*") do
                table.insert(parts, camel_part)
            end
        else
            -- No capital letters; add the part as is
            table.insert(parts, part)
        end
    end

    -- Match the prefix against split parts to calculate match score.
    local matched_parts = 0
    local prefix_idx = 1
    for parts_idx, part in ipairs(parts) do
        local part_idx = 1
        local matched_in_part = false

        -- Loop through both part and prefix to check for a match.
        while part_idx <= #part and prefix_idx <= #prefix do
            if part:sub(part_idx, part_idx) == prefix:sub(prefix_idx, prefix_idx) then
                part_idx = part_idx + 1
                prefix_idx = prefix_idx + 1
                matched_in_part = true
            else
                break
            end
        end

        if not matched_in_part then
            is_abbrev = false  -- If no match found, mark abbreviation as false
            if (parts_idx - 1) == matched_parts and matched_parts > 1 then
                is_partial_abbrev = true
            end
        else
            matched_parts = matched_parts + 1
        end
    end

    -- Track which characters in the prefix have been matched
    local matched_indices = {}
    for i = 1, #prefix do
        matched_indices[i] = false  -- Initialize all indices as unmatched
    end
    -- Calculate match score without modifying filter_text
    for i = 1, #filter_text do
        local filter_char = filter_text:sub(i, i)
        for j = 1, #prefix do
            local prefix_char = prefix:sub(j, j)

            if filter_char == prefix_char and not matched_indices[j] then
                if i == j then
                    score = score + 10  -- Exact positional match
                else
                    score = score + 5  -- Loose match
                end
                matched_indices[j] = true  -- Mark this character in prefix as matched
                break  -- Move to the next character in filter_text
            end
        end
    end

    -- Add more points if it's an abbreviation or the prefix matches exactly at the start
    -- Bonus for favorable abbreviations
    if is_abbrev and #parts > 1 then
        score = score + #prefix + 20
    end

    -- Bonus for favorable partial abbreviations
    if is_partial_abbrev and #parts > 1 then
        score = score + #prefix + 10
    end

    -- Case-insensitive match at the start
    if filter_text:sub(1, #prefix) == prefix then
        score = score + 10
    end

    -- Case-insensitive match at the start
    if filter_text:sub(1, #prefix):lower() == prefix:lower() then
        score = score + 5
    end

    -- We don't care for small matches
    if #filter_text < 4 then
        score = score - 10
    end

    -- Scoring for Consecutive Character Matches at the Start
    local consecutive_match_score = 0
    for i = 1, math.min(#filter_text, #prefix) do
        if filter_text:sub(i, i) == prefix:sub(i, i) then
            consecutive_match_score = consecutive_match_score + 1  -- Reward consecutive matches at the start more heavily
        else
            break  -- Stop if consecutive matching ends
        end
    end
    score = score + consecutive_match_score

    -- Prefer closer matches to the cursor for relevance.
    -- Determine proximity to the cursor for weighting.
    local word_line = cursor_pos[1]  -- Determine line number for the word
    local line_range = 20  -- Define the range of lines before/after the cursor
    local proximity_bonus = 0
    local closest_distance = line_range + 1  -- A large number initially

    -- Check proximity of the match in surrounding lines
    local start_line = math.max(1, word_line - line_range)
    local end_line = math.min(#buffer_lines, word_line)

    for line_num = start_line, end_line do
        local line_content = buffer_lines[line_num]
        if line_content and line_content:find(filter_text, 1, true) then
            local distance = math.abs(line_num - word_line)
            closest_distance = math.min(closest_distance, distance)
        end
    end

    if closest_distance <= line_range then
        -- The closer the match to the cursor, the higher the score
        proximity_bonus = 1.05 ^ (line_range - closest_distance)  -- Exponential decay of score
        score = score + proximity_bonus
    end

    -- python parameter
    if filter_text:sub(-1) == '=' then
        score = score + 50
    end

    -- Return the calculated match score
    return score
end

-- Function: Sorts completion entries based on the match score and other heuristics.
-- Prioritizes exact matches, abbreviations, and proximity to the cursor.
local function sort_entries(entries, prefix)
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local buffer_lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)

    local score_cache = {}

    -- Sort entries based on custom scoring criteria
    table.sort(entries, function(a, b)
        -- Use a unique key for each entry for caching
        local key_a = a.word or a.filterText or ""
        local key_b = b.word or b.filterText or ""

        -- Check cache for scores
        local filter_a_score = score_cache[key_a]
        if not filter_a_score then
            filter_a_score = calc_match_score(key_a, prefix, cursor_pos, buffer_lines)
            score_cache[key_a] = filter_a_score -- Cache the score
        end

        local filter_b_score = score_cache[key_b]
        if not filter_b_score then
            filter_b_score = calc_match_score(key_b, prefix, cursor_pos, buffer_lines)
            score_cache[key_b] = filter_b_score -- Cache the score
        end

        -- Adjust scores using user-provided additional_score_handler
        filter_a_score = additional_score_handler(filter_a_score, a)
        filter_b_score = additional_score_handler(filter_b_score, b)

        a.score = filter_a_score
        b.score = filter_b_score

        if filter_a_score == filter_b_score then
            local filter_a_length = #(a.word or a.filterText or "")
            local filter_b_length = #(b.word or b.filterText or "")

            if filter_a_length == filter_b_length then
                local filter_a_text = a.word or a.filterText or ""
                local filter_b_text = b.word or b.filterText or ""
                return filter_a_text < filter_b_text
            else
                return filter_a_length < filter_b_length
            end
        else
            return filter_a_score > filter_b_score
        end
    end)

    -- Apply additional sorting handler after sorting is complete
    return additional_sorting_handler(entries)
end

local function starts_with(text, prefix)
    -- This util function checks if 'text' starts with the given 'prefix'.
    return text:sub(1, #prefix):lower() == prefix:lower()
end

local function filter_and_sort_entries(entries, prefix)
    -- Separate entries into two lists:
    -- (1) entries that start with the prefix (likely matches),
    -- (2) entries that don't start with the prefix (unlikely matches).
    local likely_matches = {}
    local unlikely_matches = {}

    for _, entry in ipairs(entries) do
        local entry_text = entry.word or entry.filterText or ""

        -- Use a quicker pass to separate likely matches (start with prefix) and unlikely.
        if starts_with(entry_text, prefix) then
            table.insert(likely_matches, entry)
        else
            table.insert(unlikely_matches, entry)
        end
    end

    -- Sort the likely matches (those that start with the prefix)
    -- If no likely matches exist, sort the unlikely matches.
    if #likely_matches > 2 then
        sort_entries(likely_matches, prefix)
    else
        -- No likely matches, so we sort the unlikely ones as a fallback
        sort_entries(unlikely_matches, prefix)
    end

    -- Append the "unlikely matches" (unordered) after sorting likely matches,
    -- only if there are some likely matches. Otherwise, the `unlikely_matches` are already sorted.
    if #likely_matches > 0 then
        for _, entry in ipairs(unlikely_matches) do
            table.insert(likely_matches, entry)
        end
    end

    -- Assign incremental scores to the entries, in the order they are now listed.
    local final_list = #likely_matches > 0 and likely_matches or unlikely_matches
    for i, entry in ipairs(final_list) do
        entry.score = i
    end

    -- Return the final sorted list, combining the sorted and unsorted parts.
    return final_list
end

-- Function: Show completion cache
local function show_cache(bufnr, force)
    local mode = api.nvim_get_mode()['mode']
    if not context[bufnr] then
        log(string.format("No context for buffer %d", bufnr))
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})
        end
        return
    end

    -- Get current state
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor_pos[1]
    local col = vim.fn.charcol('.')
    local line = vim.api.nvim_get_current_line()
    local before_text = col == 1 and '' or line:sub(1, col - 1)
    local has_dot = before_text:sub(-1) == '.'

    log(string.format("show_cache - line: %d, col: %d, has_dot: %s", current_line, col, has_dot))

    local ok, retval = pcall(vim.fn.matchstrpos, before_text, '\\k*$')
    local prefix, start_idx = retval[1], retval[2]

    -- Check if any client needs to show results or context changed
    local need_update = force or false  -- Initialize with force value
    local context_changed = false
    for client_id, client_state in pairs(context[bufnr].clients) do
        if client_state.last_prefix ~= prefix or
           client_state.last_start_idx ~= start_idx or
           client_state.last_line ~= current_line then
            need_update = true
            log(string.format("Client %d needs update - current prefix: %s, last prefix: %s",
                client_id, prefix, client_state.last_prefix))

            if has_dot then
                client_state.cache = {}
            end

            -- Context changed if any client has different start_idx, line or prefix
            if (client_state.last_start_idx and client_state.last_start_idx ~= start_idx) or
               (client_state.last_line and client_state.last_line ~= current_line) then
                client_state.context_changed = true
                log(string.format("Context changed for client %d", client_id))
            end
        end
    end

    if not need_update and vim.fn.pumvisible() == 1 then
        log("No update needed and popup menu is visible")
        return
    end

    -- Aggregate entries from all clients
    local combined_entries = {}
    local entry_set = {}  -- To track duplicates

    for client_id, client_state in pairs(context[bufnr].clients) do
        -- Update client state
        client_state.last_prefix = prefix
        client_state.last_start_idx = start_idx
        client_state.last_line = current_line

        log(string.format("Processing %d entries from client %d", #client_state.cache, client_id))

        -- Add entries from this client's cache
        for _, entry in ipairs(client_state.cache) do
            local key = entry.word .. (entry.menu or '') .. (entry.abbr or '')
            if not entry_set[key] then
                entry.client_id = client_id
                table.insert(combined_entries, entry)
                entry_set[key] = true
            elseif entry_set[key] then
                -- If entry already exists, keep the one with higher score
                for i, existing in ipairs(combined_entries) do
                    if existing.word .. (existing.menu or '') .. (existing.abbr or '') == key then
                        if (entry.score or 0) > (existing.score or 0) then
                            combined_entries[i] = entry
                        end
                        break
                    end
                end
            end
        end
    end

    log(string.format("Combined %d entries, context_changed: %s", #combined_entries, context_changed))

    -- Sort and display the combined results
    if #combined_entries > 0 then
        local sort_and_display_results = function()
            local sorted_entries = filter_and_sort_entries(combined_entries, prefix)

            if (mode == 'i' or mode == 'ic') and #sorted_entries > 0 then
                if vim.fn.complete_info({ 'selected' }).selected == -1 then
                    log(string.format("Displaying %d entries at position %d", #sorted_entries, start_idx + 1))
                    vim.fn.complete(start_idx + 1, sorted_entries)
                    complete_ondone(bufnr)
                end
            end
        end

        -- Check if we should defer sorting
        if vim.fn.pumvisible() == 1 and #combined_entries > 2000 then
            log("Deferring sort for large result set")
            vim.defer_fn(function()
                sort_and_display_results()
            end, 1)
        else
            sort_and_display_results()
        end
    else
        log("No entries to display")
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})
        end
    end
end

-- Function: Retrieve the item kind from LSP completion.
-- Customizes how LSP kinds (like Function, Method, etc.) are displayed.
local function lspkind(kind)
    -- Retrieve the LSP Completion Item Kind and use predefined formatting
    local k = protocol.CompletionItemKind[kind] or 'Unknown'
    return kind_format(k)
end

-- Function: Process individual completion items for LSP completion.
-- Customizes and processes each item based on context, filter, and validation criteria.
local function process_completion_item(item)
    local entry = {
        abbr = vim.fn.strcharpart(item.label .. string.rep(' ', pum_width), 0, pum_width),
        kind = lspkind(item.kind),
        icase = 1,
        dup = 1,
        empty = 1,
        equal = 1,
        user_data = {
            nvim = {
                lsp = {
                    completion_item = item,
                },
            },
        },
    }

    -- print(vim.inspect(item))
    -- Handle entry formatting using additional_format_completion
    if item.detail and #item.detail > 0 then
        entry.menu = vim.split(item.detail, "\n", { trimempty = true })[1]
    end

    if item.labelDetails then
        entry.abbr = item.label .. ' +'.. item.labelDetails.description
        entry.abbr = vim.fn.strcharpart(entry.abbr .. string.rep(' ', pum_width), 0, pum_width)
    end
    -- Set the word as before
    local textEdit = vim.tbl_get(item, 'textEdit')
    if textEdit then
        entry.word = textEdit.newText
    elseif item.insertText then
        entry.word = item.insertText
    else
        entry.word = item.label
    end

    -- Apply additional formatting
    entry = additional_format_completion(entry)

    return entry
end
-- Keep track of buffers that already have CompleteDone autocmd
local complete_done_registered = {}

-- Function: Handle 'CompleteDone' autocommand
function complete_ondone(bufnr)
    if complete_done_registered[bufnr] then
        return
    end

    complete_done_registered[bufnr] = true

    api.nvim_create_autocmd('CompleteDone', {
        group = zap_augroup,
        buffer = bufnr,
        callback = function(args)
            local item = vim.v.completed_item
            if not item or vim.tbl_isempty(item) then
                return
            end

            local cp_item = vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item')
            if not cp_item then
                return
            end

            local client = lsp.get_clients({ id = context[args.buf].client_ids[0] })[1]
            if not client then
                return
            end

            if cp_item.additionalTextEdits then
                lsp.util.apply_text_edits(cp_item.additionalTextEdits, bufnr, client.offset_encoding)
            end
        end,
    })

    api.nvim_create_autocmd('BufDelete', {
        group = zap_augroup,
        buffer = bufnr,
        callback = function()
            complete_done_registered[bufnr] = nil
        end,
    })
end

-- Function: Main completion handler
local function completion_handler(_, result, ctx)
    if not result or not api.nvim_buf_is_valid(ctx.bufnr) then
        log("LSP Completion: Invalid result or buffer")
        return
    end

    -- Ignore if completion item is selected
    if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'selected' }).selected ~= -1 then
        return
    end

    -- Get current position
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local col = vfn.charcol('.')
    local line = api.nvim_get_current_line()
    local before_text = col == 1 and '' or line:sub(1, col - 1)

    -- Get current context
    local ok, retval = pcall(vfn.matchstrpos, before_text, '\\k*$')
    if not retval or #retval == 0 then
        log("Invalid match position")
        return
    end
    local _, current_start_idx = retval[1], retval[2]

    -- Validate position matches
    if current_start_idx ~= ctx.start_idx or
       current_line ~= ctx.line_number then
        log(string.format("Position mismatch - current: %d, %d; context: %d, %d",
            current_start_idx, current_line, ctx.start_idx, ctx.line_number))
        return
    end

    -- Check for stale response
    local client_state = request_state[ctx.bufnr] and request_state[ctx.bufnr][ctx.client_id]
    if client_state and (
        client_state.last_start_idx ~= current_start_idx or
        client_state.last_line ~= current_line
    ) then
        log("Stale response detected")
        return
    end

    -- Handle both individual and categorized completion item lists
    local compitems = vim.islist(result) and result or result.items
    log(string.format("Processing %d completion items for buffer %d", #compitems, ctx.bufnr))
    if #compitems == 0 then
        log("No completion items")
        return
    end

    -- Initialize client cache if needed
    if not context[ctx.bufnr].clients[ctx.client_id] then
        context_init(ctx.bufnr, ctx.client_id)
    end

    local client_cache = context[ctx.bufnr].clients[ctx.client_id]
    local entry_set = {}
    local force_update = false
    if client_cache.context_changed then
        client_cache.cache = {}
        client_cache.context_changed = false
        force_update = true
    end

    -- Process and insert fresh items while removing duplicates
    for _, item in ipairs(compitems) do
        local entry = process_completion_item(item)
        local menu = entry.menu or ''
        local key = entry.word .. menu .. entry.abbr
        if entry_set[key] then
            local existing_idx = entry_set[key]
            client_cache.cache[existing_idx] = entry
        else
            table.insert(client_cache.cache, entry)
            entry_set[key] = #client_cache.cache
        end
    end

    log(string.format("Added/updated entries in cache for client %d, total entries: %d",
        ctx.client_id, #client_cache.cache))

    -- Show combined cache from all clients
    show_cache(ctx.bufnr, force_update)
end

-- Function: Debounce completions
local function debounce(client, bufnr)
    -- Get current position info
    local col = vfn.charcol('.')
    local line = api.nvim_get_current_line()
    local before_text = col == 1 and '' or line:sub(1, col - 1)
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local has_dot = before_text:sub(-1) == '.'

    -- Extract prefix and start index
    local ok, retval = pcall(vfn.matchstrpos, before_text, '\\k*$')
    if not retval or #retval == 0 then
        log("No retval in debounce")
        return
    end
    local initial_prefix, initial_start_idx = retval[1], retval[2]

    log(string.format("Debounce - Client %d, Prefix: '%s', Start Index: %d, Line: %d",
        client.id, initial_prefix, initial_start_idx, current_line))

    -- Initialize request state
    if not request_state[bufnr] then
        request_state[bufnr] = {}
    end

    -- In the request_state initialization (in debounce function)
    if not request_state[bufnr][client.id] then
        request_state[bufnr][client.id] = {
            in_progress = false,
            request_another = false,
            last_start_idx = nil,
            last_line = nil,
            context_changed = false  -- Add this flag
        }
    end

    local client_state = request_state[bufnr][client.id]

    -- Skip if request in progress at same position
    if client_state.in_progress and
       client_state.last_start_idx == initial_start_idx and
       client_state.last_line == current_line then
       client_state.request_another = true
       log("Request another set")
        return
    end

    -- Update client state
    client_state.in_progress = true
    client_state.last_start_idx = initial_start_idx
    client_state.last_line = current_line

    -- Prepare LSP request
    local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding)

    -- Check if we should adjust the position
    local client_cache = context[bufnr] and context[bufnr].clients[client.id]
    local cache_empty = not client_cache or #(client_cache.cache or {}) == 0

    if not cache_empty and client_cache.context_changed then
        log("Adjusting position character to start_idx")
        params.position.character = initial_start_idx
        client_state.request_another = true
    end

    client.request(ms.textDocument_completion, params, function(err, result, response_ctx)
        response_ctx.prefix = initial_prefix
        response_ctx.start_idx = initial_start_idx
        response_ctx.line_number = current_line
        response_ctx.client_id = client.id

        client_state.in_progress = false

        completion_handler(err, result, response_ctx)

        -- client_cache = context[bufnr] and context[bufnr].clients[client.id]
        -- cache_empty = not client_cache
        -- if not cache_empty then
        -- end

        if client_state.request_another then
            client_state.request_another = false
            log("Triggering another request")
            debounce(client, bufnr)
        end
    end, bufnr)
end

-- Function: Setup autocompletion
local function auto_complete(client, bufnr)
    local function trigger_completion(args)
        if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'selected' }).selected ~= -1 then
            return
        end

        local first_client = context[args.buf].client_ids[1]
        if client.id == first_client then
            show_cache(args.buf)
        end

        debounce(client, args.buf)
    end

    if not context[bufnr] then
        context_init(bufnr, client.id)
    else
        table.insert(context[bufnr].client_ids, client.id)
    end

    vim.api.nvim_create_autocmd('TextChangedI', {
        group = zap_augroup,
        buffer = bufnr,
        callback = function(args) trigger_completion(args) end,
    })

    vim.api.nvim_create_autocmd('InsertEnter', {
        group = zap_augroup,
        buffer = bufnr,
        callback = function(args) trigger_completion(args) end,
    })

    vim.api.nvim_create_autocmd('CursorHold', {
        group = zap_augroup,
        buffer = bufnr,
        callback = function(args) trigger_completion(args) end,
    })

    vim.api.nvim_create_autocmd('TextChangedP', {
        group = zap_augroup,
        buffer = bufnr,
        callback = function(args) trigger_completion(args) end,
    })
end

-- Function: LSP registration capabilities
local function register_cap()
    return {
        textDocument = {
            completion = {
                completionItem = {
                    snippetSupport = vim.snippet and true or false,
                    resolveSupport = {
                        properties = { 'edit', 'documentation', 'detail', 'additionalTextEdits' },
                    },
               },
            },
        },
    }
end

-- Helper variable to track already attached buffers
local attached_buffers = {}

-- Function: Master setup function for the module, configuring options and autocommands.
-- Handles LSP on_attach, snippet extension, completion triggers, and other setups.
local function setup(opt)
    -- Options applied to the module
    pum_width = opt.pum_width or pum_width
    kind_format = opt.kind_format or function(k) return k:lower():sub(1, 1) end

    -- New options for additional functionality
    additional_format_completion = opt.additional_format_completion or function(entry) return entry end
    additional_score_handler = opt.additional_score_handler or function(score, entry) return score end
    additional_sorting_handler = opt.additional_sorting_handler or function(entries) return entries end

    local function on_attach(client, bufnr)
        -- Avoid attaching to buffers multiple times
        if not attached_buffers[tostring(client.id) .. '_' .. tostring(bufnr)] then
            attached_buffers[tostring(client.id) .. '_' .. tostring(bufnr)] = true
        end

        -- Setup autocompletion for the attached buffer
        auto_complete(client, bufnr)
    end

    -- Create an autocommand group to manage LspAttach events
    vim.api.nvim_create_augroup("LspSetupGroup", { clear = false })
    vim.api.nvim_create_autocmd('LspAttach', {
        group = "LspSetupGroup",
        callback = function(args)
            -- On LSP attachment to a buffer, call the on_attach function with client and buffer reference
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client then
                return
            end
            on_attach(client, args.buf)
        end,
    })
end

-- Return public-facing functions of the module
return {
    setup = setup,
    register_cap = register_cap,
}
