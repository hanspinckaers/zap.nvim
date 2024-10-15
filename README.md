## zap.nvim

:zap: fast, typo-resistant, fuzzy LSP auto-completion plugin for Neovim.

**Requires Neovim nightly**

> [!NOTE]  
> zap.nvim is heavily inspired by [`epo.nvim`](https://github.com/nvimdev/epo.nvim), but has evolved into a fast and typo-resistant completion plugin. It supports multiple LSPs per buffer. However, it currently does not support snippets or provide additional info.

## Usage

```lua
-- Suggested completeopt
vim.opt.completeopt = "menu,menuone,noselect"

-- Default settings
require('zap').setup({
    -- Debounce time to avoid triggering complete too frequently
    debounce_time = 2,
    -- Width of the completion popup menu
    pum_width = 33,
    -- Format LSP kind indicators, e.g., "Field", "Struct", "Keyword"
    kind_format = function(k)
      return k:lower():sub(1, 1)
    end,
    -- Custom formatting for completion entries
    additional_format_completion = function(entry)
        return entry  -- Default does nothing, can be customized
    end,
    -- Adjust score of particular completion entries
    additional_score_handler = function(score, entry)
        return score  -- Default does nothing, can be customized
    end,
    -- Customize sorting of completion entries
    additional_sorting_handler = function(entries)
        return entries  -- Default does nothing, can be customized
    end,
})

```

To pass the enhanced capabilities to your LSP client:

```lua
local capabilities = vim.tbl_deep_extend(
      'force',
      vim.lsp.protocol.make_client_capabilities(),
      require('zap').register_cap()
    )
```

### Python-Specific Configuration

Here's an example setup for Python, using `pyright` and optionally integrating with `jedi`:

```lua
-- Python-specific configuration with zap.nvim setup functions
local zap = require('zap')

zap.setup({
    -- Customize to replace menu label for auto-import entries
    additional_format_completion = function(entry)
        if entry.menu == "Auto-import" then
            entry.menu = "+"
        end
        return entry
    end,

    -- Adjust score logic for particular entries
    additional_score_handler = function(score, entry)
        if entry.menu and entry.menu:sub(1, 1) == '+' then
            return score - 3  -- Lower priority for auto-import entries
        end
        return score
    end,

    -- Sort normal entries before certain categorized ones
    additional_sorting_handler = function(entries)
        local function is_auto_import(entry)
            return entry.menu and entry.menu:sub(1, 1) == '+'
        end
        local normal_entries, modified = {}, {}
        
        for i, entry in ipairs(entries) do
            if not is_auto_import(entry) then
                table.insert(normal_entries, entry)
                if #normal_entries == 2 then
                    table.insert(modified, normal_entries[1])
                    table.insert(modified, normal_entries[2])
                    for j = 1, #entries do
                        if is_auto_import(entries[j]) or (j > 2 and not vim.tbl_contains(normal_entries, entries[j])) then
                            table.insert(modified, entries[j])
                        end
                    end
                    for k = 1, #modified do
                        entries[k] = modified[k]
                    end
                    return entries
                end
            end
        end
        return entries
    end,
})

-- LSP setup for pyright and (optionally) jedi
local lspconfig = require('lspconfig')
lspconfig.pyright.setup {
    capabilities = capabilities,
    on_attach = function(client, bufnr)
        -- ... Additional buffer or client-specific settings
    end,
}

lspconfig.jedi_language_server.setup({
    capabilities = capabilities,
    on_attach = function(client, bufnr)
        -- ... Additional buffer or client-specific settings
    end,
})
```

If the completion menu appears dull, ensure your colorscheme includes these highlights:

```
Pmenu
PmenuExtra
PmenuSel
PmenuKind
PmenuKindSel
PmenuExtraSel
PmenuSbar
PmenuThumb
```

### <kbd>TAB</kbd> for completion cycling:

```lua
vim.keymap.set('i', '<TAB>', function()
  if vim.fn.pumvisible() == 1 then
    return '<C-n>'
  elseif vim.snippet and vim.snippet.jumpable(1) then
    return '<cmd>lua vim.snippet.jump(1)<cr>'
  else
    return '<TAB>'
  end
end, { expr = true })

vim.keymap.set('i', '<S-TAB>', function()
  if vim.fn.pumvisible() == 1 then
    return '<C-p>'
  elseif vim.snippet and vim.snippet.jumpable(-1) then
    return '<cmd>lua vim.snippet.jump(-1)<CR>'
  else
    return '<S-TAB>'
  end
end, { expr = true })

```

## License

MIT
