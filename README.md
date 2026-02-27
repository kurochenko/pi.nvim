# pi.nvim

Neovim plugin that integrates the [Pi](https://pi.dev) coding agent into a side panel with bidirectional context passing — select code in Neovim and send it to Pi with a single keypress.

## Requirements

- Neovim ≥ 0.10
- [pi](https://pi.dev) CLI installed and in PATH
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, recommended — provides terminal management and input UI)

## Installation

### lazy.nvim

```lua
{
  dir = "~/projects/personal/nvim-pi",  -- local development
  -- or: "andrej/pi.nvim",             -- once published
  dependencies = {
    { "folke/snacks.nvim", optional = true },
  },
  config = function()
    require("pi").setup({
      -- your overrides here (see Configuration)
    })
  end,
}
```

## Default Keymaps

| Key | Mode | Action |
|-----|------|--------|
| `<leader>pt` | n, t | Toggle pi panel |
| `<leader>pa` | n, v | Ask pi about code / selection (opens input prompt) |
| `<leader>px` | n, v | Action picker (prompts + controls) |
| `<leader>pp` | n, v | Send code context directly to pi |
| `<leader>pq` | n | Abort pi's current operation |

All keymaps can be changed or disabled individually:

```lua
require("pi").setup({
  keymaps = {
    toggle = "<C-.>",       -- change the binding
    abort = false,          -- disable this keymap
  },
})
```

## Usage

1. **Toggle panel**: `<leader>pt` opens pi in a side panel. Pi runs its full interactive TUI — you can interact with it directly there.

2. **Ask about code**: Select code in visual mode, press `<leader>pa`, type your question (e.g. "explain this"), press Enter. The selected code is automatically included as context.

3. **Action picker**: Press `<leader>px` to choose from pre-configured prompts: explain, review, fix, test, document, optimize, implement, diff.

4. **Direct send**: `<leader>pp` sends code context to pi immediately without an input dialog.

5. **Commands**: `:Pi toggle`, `:Pi ask <text>`, `:Pi prompt explain`, `:Pi select`, `:Pi abort`

### Context Placeholders

Prompts can include `@placeholders` that are resolved from your editor state:

| Placeholder | Content |
|-------------|---------|
| `@this` | Visual selection, or code around cursor (±5 lines) |
| `@buffer` | Full buffer content (truncated at 500 lines) |
| `@buffers` | List of all loaded file buffers with previews |
| `@visible` | Content visible in all windows |
| `@diagnostics` | LSP diagnostics for current buffer |
| `@quickfix` | Quickfix list entries |
| `@diff` | Git diff output |

Example: `<leader>pa` → type `fix the error in @this based on @diagnostics` → code + diagnostics are inlined into the prompt sent to pi.

## Configuration

All defaults:

```lua
require("pi").setup({
  terminal = {
    position = "right",       -- "left", "right", or "bottom"
    size = 0.4,               -- fraction of screen (0.0-1.0)
    cmd = "pi",               -- pi executable
    continue_session = true,  -- pass -c flag (continue previous session)
    auto_start = false,       -- open panel on setup
  },

  prompts = {
    explain  = { text = "Explain @this and its context", submit = true },
    review   = { text = "Review @this for correctness and readability", submit = true },
    fix      = { text = "Fix @diagnostics", submit = true },
    test     = { text = "Add tests for @this", submit = true },
    document = { text = "Add documentation comments to @this", submit = true },
    optimize = { text = "Optimize @this for performance and readability", submit = true },
    implement = { text = "Implement @this", submit = true },
    diff     = { text = "Review the following git diff for correctness and readability: @diff", submit = true },
    -- Set any to false to remove: fix = false
  },

  contexts = {
    ["@this"] = true,
    ["@buffer"] = true,
    ["@buffers"] = true,
    ["@visible"] = true,
    ["@diagnostics"] = true,
    ["@quickfix"] = true,
    ["@diff"] = true,
    -- Set any to false to disable
  },

  ask = {
    prompt = "pi> ",
    snacks = {},  -- snacks.input window options
  },

  keymaps = {
    toggle = "<leader>pt",
    ask = "<leader>pa",
    select = "<leader>px",
    prompt_this = "<leader>pp",
    abort = "<leader>pq",
  },

  events = {
    reload = true,  -- auto-reload buffers on FocusGained/BufEnter
  },
})
```

## Coexistence with opencode.nvim

pi.nvim uses `<leader>p` prefix keymaps by default, which don't conflict with opencode.nvim's bindings. Both can run simultaneously — they manage separate terminal instances with different filetypes (`pi_terminal` vs opencode's terminal).

## Architecture

Pi runs in an embedded Neovim terminal buffer. When you trigger a prompt:
1. Your selection/context is captured from the editor
2. `@placeholders` in the prompt are resolved to actual code content
3. The resolved text is injected into pi's TUI editor via [bracketed paste](https://en.wikipedia.org/wiki/Bracketed-paste)
4. Pi processes the prompt and you see the response in its TUI panel
5. When pi edits files, Neovim auto-detects changes via `checktime`

## License

MIT
