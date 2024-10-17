-- Lua-based Neovim LSP configuration for autocompletion setup
-- Import necessary modules and functions
local api, vfn, uv, lsp = vim.api, vim.fn, vim.uv, vim.lsp
local protocol = require('vim.lsp.protocol')
local util = require('vim.lsp.util')
local ms = protocol.Methods

-- Create a unique highlight namespace and user-defined augroup
local zap_augroup = api.nvim_create_augroup('Zap', { clear = true })  -- User-defined autocommand group

-- Configuration defaults and variables
local debounce_time = 2
local pum_width = 33
local kind_format = nil

-- State to prevent auto-completion redisplay and save cache
local context = {
    last_prefix = nil,
    last_start_idx = nil,
    client_ids = {}, -- Store multiple client IDs
}

local additional_format_completion = function(entry) return entry end
local additional_score_handler = function(score, entry) return score end
local additional_sorting_handler = function(entries) return entries end

-- Function: Initialize buffer-specific context.
-- Handles the state saved by the module for each buffer.
local function context_init(bufnr, id)
    context[bufnr] = {
        timer = nil,      -- Timer for debounce purposes
        client_ids = {},  -- List of LSP client IDs
        cache = {},       -- Cached completion items
    }
    table.insert(context[bufnr].client_ids, id) -- Add the new client ID
end

local function split(input_str, sep)
    local result = {}
    for str in input_str:gmatch("([^" .. sep .. "]+)") do
        table.insert(result, str)
    end
    return result
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

-- Function: Show currently cached autocompletion items, immediately display cached
-- entries and defer re-sorting for later smoother experience.
-- This function also invalidates previous timers to ensure only the latest deferred sorting is executed.
local function show_cache(args)
    local bufnr = args.buf
    local mode = api.nvim_get_mode()['mode']  -- Re-check mode when the timer executes

    -- Proceed only if a valid cache exists for this buffer
    if not context[bufnr] or not context[bufnr].cache then
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})  -- Hide the completion menu if there's no cache
        end
        return
    end


    -- Get the current state of the line and word before the cursor
    local col = vim.fn.charcol('.')
    local line = vim.api.nvim_get_current_line()
    local before_text = col == 1 and '' or line:sub(1, col - 1)

    -- Validate that we can extract prefix and start index from the current input
    local ok, retval = pcall(vim.fn.matchstrpos, before_text, '\\k*$')

    if not ok or not retval or #retval == 0 then
        context[bufnr].cache = {}
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})  -- Ensure the complete menu is hidden after clearing cache
        end
        return  -- Exit gracefully if there's an error in matching the string
    end

    local prefix, start_idx = retval[1], retval[2]
    if context[bufnr].last_start_idx ~= start_idx then
        context[bufnr].cache = {}
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})  -- Ensure the complete menu is hidden after clearing cache
        end
        return
    end

    -- Avoid redundant cache retrieval by checking if the prefix/start index matches previous values
    if context[bufnr].last_prefix == prefix and context[bufnr].last_start_idx == start_idx then
        return
    end

    -- Save the latest prefix and starting index
    context[bufnr].last_prefix = prefix
    context[bufnr].last_start_idx = start_idx

    -- Immediate check of whether the prefix is valid (and whether it’s empty)
    local prefix_word = prefix:gsub("%s+", "")
    if #prefix_word == 0 then
        context[bufnr].cache = {}
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})  -- Hide the completion menu when there's no prefix (empty cache)
        end
        return
    end

    -- Always sort the entries (this operation is slow and should be deferred if possible)
    local sort_and_display_results = function()
        local re_filtered_sorted_entries = filter_and_sort_entries(
            context[bufnr].cache, prefix
        )

        -- After sorting, attempt to open the completion menu
        if (mode == 'i' or mode == 'ic') and #re_filtered_sorted_entries > 0 then
            if vim.fn.complete_info({ 'selected' }).selected == -1 then
                vim.fn.complete(start_idx + 1, re_filtered_sorted_entries)  -- Show the sorted result
            end
        end
    end

     -- Check if the completion menu (popup menu) is visible
    if vim.fn.pumvisible() == 1 then
        -- Only defer the sorting if the item count is greater than 1000
        if #context[bufnr].cache > 1000 then
            -- If there are more than 1000 items and the popup menu is visible, defer sorting
            vim.defer_fn(function()
                sort_and_display_results()
            end, 1)  -- Defer sorting by 1 ms (this is to not delay display of characters when typing)
        else
            -- If fewer than 1000 items, process directly
            sort_and_display_results()
        end
    else
        -- If the popup menu is not visible, sort and show results immediately
        sort_and_display_results()
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

    -- Handle entry formatting using additional_format_completion
    if item.detail and #item.detail > 0 then
        entry.menu = vim.split(item.detail, "\n", { trimempty = true })[1]
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

-- Function: Handle 'CompleteDone' autocommand behavior upon LSP completion.
-- Tasks include applying additional edits, resolving snippets, and triggering signature help.
local function complete_ondone(bufnr)
    api.nvim_create_autocmd('CompleteDone', {
        group = zap_augroup,
        buffer = bufnr,
        once = true,
        callback = function(args)
            -- Retrieve the completed item from VIM's completion environment
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

            -- Reset any potential menu and cache issues here
            context[args.buf].cache = {}

            -- Apply additional text edits if the completion item includes them
            if cp_item.additionalTextEdits then
                lsp.util.apply_text_edits(cp_item.additionalTextEdits, bufnr, client.offset_encoding)
            end
        end,
    })
end


-- Function: Main completion handler to process LSP completion results.
-- Handles caching, filtering, sorting, and invoking Neovim's native completion system.
local function completion_handler(_, result, ctx)
    if not result or not api.nvim_buf_is_valid(ctx.bufnr) then
        return
    end
    -- Handle both individual and categorized completion item lists provided by the LSP server
    local compitems = vim.islist(result) and result or result.items
    local col = vfn.charcol('.')
    local line = api.nvim_get_current_line()
    local before_text = col == 1 and '' or line:sub(1, col - 1)

    -- Capture the current word context and determine start index
    local ok, retval = pcall(vfn.matchstrpos, before_text, '\\k*$')
    if not ok or not #retval == 0 then
        return
    end
    local prefix, start_idx = unpack(retval)

    -- Check if the prefix and start index match the expected context
    if start_idx ~= ctx.start_idx then
        return
    end

    -- Track unique entries to avoid duplicates
    local entry_set = {}

    if context[ctx.bufnr].cache and context[ctx.bufnr].last_start_idx == start_idx then
        -- Initialize entry set with current in-cache entries
        for idx, entry in ipairs(context[ctx.bufnr].cache) do
            local menu = entry.menu or ''
            entry_set[entry.word .. menu .. entry.abbr] = idx
        end
    else
        context[ctx.bufnr].cache = {}
    end

    context[ctx.bufnr].last_start_idx = start_idx

    -- Process and insert fresh items while removing duplicates
    for _, item in ipairs(compitems) do
        local entry = process_completion_item(item)

        local menu = entry.menu or ''
        -- Check if we already have this entry in the entry_set
        if entry_set[entry.word .. menu .. entry.abbr] then
            local existing_idx = entry_set[entry.word .. menu .. entry.abbr]
            context[ctx.bufnr].cache[existing_idx] = entry  -- Replace the old entry with the new one
        else
            -- If the entry does not exist, add it to the cache
            table.insert(context[ctx.bufnr].cache, entry)
            entry_set[entry.word] = #context[ctx.bufnr].cache  -- Store the index in entry_set
        end
    end

    -- Save prefix and start index for future processing
    context[ctx.bufnr].last_prefix = prefix
    context[ctx.bufnr].last_start_idx = start_idx

    -- Sort and filter cached items based on the current prefix
    local valid_entries = filter_and_sort_entries(context[ctx.bufnr].cache, prefix)

    -- If no valid entries, hide the completion
    if #valid_entries == 0 then
        local mode = vim.api.nvim_get_mode().mode
        if (mode == 'i' or mode == 'ic') then
            vim.fn.complete(1, {})  -- <-- Hide complete menu when no valid entries.
        end
        return
    end

    -- Schedule completion after a small delay (debounce)
    local mode = api.nvim_get_mode()['mode']  -- Re-check mode when the timer executes

    -- Only call completion within insert or completion mode
    if mode == 'i' or mode == 'ic' then
        local has_dot = before_text:sub(-1) == '.'
        if #prefix > 0 or has_dot then
            if vim.fn.complete_info({ 'selected' }).selected == -1 then
                local startcol = start_idx + 1
                vfn.complete(startcol, valid_entries)  -- Trigger autocompletion popup
                complete_ondone(ctx.bufnr)
            end
        end
    end
end


-- Table to store client-specific debounce timers per buffer
local debounce_timers = {}

-- Function: Debounce the LSP completion process to reduce resource usage.
-- Limits how often completion requests are made during rapid typing.
local function debounce(client, bufnr)
    -- Obtain the current column and line where the cursor is positioned
    local col = vfn.charcol('.')
    local line = api.nvim_get_current_line()
    local before_text = col == 1 and '' or line:sub(1, col - 1)

    -- Extract the prefix and start index initially
    local ok, retval = pcall(vfn.matchstrpos, before_text, '\\k*$')
    if not ok or not retval or #retval == 0 then
        return
    end
    local initial_prefix, initial_start_idx = retval[1], retval[2]

    if #initial_prefix <= 1 then
        local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding)
        client.request(ms.textDocument_completion, params, function(err, result, response_ctx)
            -- Append the prefix and start_idx to the existing context
            response_ctx.prefix = initial_prefix
            response_ctx.start_idx = initial_start_idx
            
            -- Call the completion_handler with the modified context
            completion_handler(err, result, response_ctx)
        end, bufnr)
        return
    end

    -- Debounce logic for longer prefixes
    if not debounce_timers[bufnr] then
        debounce_timers[bufnr] = {}
    end

    -- Close any existing timer for the current client if active
    local timer = debounce_timers[bufnr][client.id]
    if timer then
        timer:stop()
        timer:close()
        debounce_timers[bufnr][client.id] = nil
    end

    -- Start a new debounce timer for this client
    timer = uv.new_timer()
    debounce_timers[bufnr][client.id] = timer
    timer:start(debounce_time, 0, vim.schedule_wrap(function()
        local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding)
        client.request(ms.textDocument_completion, params, function(err, result, response_ctx)
            -- Append the prefix and start_idx to the existing context
            response_ctx.prefix = initial_prefix
            response_ctx.start_idx = initial_start_idx

            -- Call the completion_handler with the modified context
            completion_handler(err, result, response_ctx)
        end, bufnr)

        -- Clean up the timer after the request is sent
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
            debounce_timers[bufnr][client.id] = nil
        end
    end))
end
-- Function: Handles LSP-driven autocompletion during typing, triggered by specific events.
-- Registers relevant autocommands to handle completion dynamically during typing.
local function auto_complete(client, bufnr)
    local function trigger_completion(args)
        -- Inhibit autocompletion if a user has selected a completion item from the popup
        if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'selected' }).selected ~= -1 then
            return
        end

        -- Show cached completions if any are available
        local first_client = context[args.buf].client_ids[1]
        if client.id == first_client then
            show_cache(args)
        end

        -- Request completion from LSP client with a debounce cycle
        debounce(client, args.buf)
    end

    -- Initialize the buffer's context if not already initialized
    if not context[bufnr] then
        context_init(bufnr, client.id)
    else
        table.insert(context[bufnr].client_ids, client.id) -- Add the new client ID
    end


    -- Register autocommands to trigger completions upon relevant events
    vim.api.nvim_create_autocmd('TextChangedI', {
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

-- Function: LSP registration capabilities for completions.
-- Sets up support for snippets, resolve support for additional
-- data fields, and other related options.
-- @return Capabilities object for LSP server.
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
    debounce_time = opt.debounce_time or debounce_time
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
