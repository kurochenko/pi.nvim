# pi.nvim

Neovim plugin for the [Pi](https://pi.dev) coding agent. Embeds pi's interactive TUI in a terminal panel with bidirectional context passing from Neovim.

## Goals

- Run pi in a side panel (embedded terminal with full TUI)
- Send editor context (selection, buffer, diagnostics, diff) to pi via keybindings
- Auto-reload buffers when pi edits files
- Coexist with opencode.nvim (separate keybindings and terminal instances)
- Minimal codebase (~700 LOC Lua), snacks.nvim optional

## Architecture: Terminal + Bracketed Paste

Pi's interactive TUI is excellent — session tree, model picker, streaming display, tool output rendering, themes. Rebuilding any of that in Neovim buffers would be massive effort. Instead, we embed pi's TUI directly.

### How It Works

1. Pi runs in a Neovim terminal buffer (via `snacks.terminal` or manual `termopen`)
2. User selects code in their editor, presses a keymap
3. pi.nvim captures the context (selection, file path, diagnostics, etc.)
4. `@placeholders` in the prompt are resolved to actual inline content
5. The resolved prompt is injected into pi's TUI editor via **bracketed paste**:
   - `Ctrl+C` clears pi's current editor content
   - `\x1b[200~` starts bracketed paste (TUI treats content as pasted text)
   - Prompt text is sent (multi-line, with code blocks)
   - `\x1b[201~` ends bracketed paste
   - `\r` (Enter) submits the prompt
6. Pi processes the prompt and shows the response in its TUI
7. When pi edits files, Neovim detects changes via `autoread` + `checktime`

### Why Not RPC?

Pi has a complete `--mode rpc` JSON-over-stdin/stdout protocol. A pure RPC approach would give us structured events (streaming status, file edit notifications, extension UI). However:

- We'd need to build a custom output renderer (markdown buffer with tool call rendering)
- We'd lose pi's TUI: session tree, model picker, themes, interactive tool output
- The terminal approach is proven (opencode.nvim uses the same pattern)
- Much simpler to implement (~700 LOC vs ~1500+ LOC)

**Phase 2** may add an RPC sidecar for enhanced features (statusline, structured file reload, extension UI handling) while keeping the terminal as the primary display.

### Differences from opencode.nvim

| | opencode.nvim | pi.nvim |
|---|---|---|
| Communication | HTTP REST + SSE (via curl) | Bracketed paste to terminal stdin |
| Server discovery | Port scanning (lsof/pgrep) | Direct child process |
| Context format | `@file L21:C10-L65:C11` references | Inline code content in prompt |
| Dependencies | snacks.nvim required | snacks.nvim optional |
| Keybindings | `<C-a>`, `<C-x>`, `<C-.>` | `<leader>p*` prefix (coexists) |

## Module Structure

```
lua/pi/
  init.lua       -- Public API: setup(), ask(), prompt(), select(), toggle(), abort(), operator()
  config.lua     -- Configuration defaults and deep-merge setup
  terminal.lua   -- Terminal panel: open/close/toggle, bracketed paste injection
  context.lua    -- Context extraction: @this, @buffer, @diagnostics, @diff, etc.
plugin/
  pi.lua         -- Auto-setup, highlight groups, file reload autocmds, :Pi command
```

## Context Providers

Each provider is a function that returns a formatted string or nil.

| Placeholder | Source | Format |
|-------------|--------|--------|
| `@this` | Visual selection or cursor ±5 lines | File path + language-fenced code block |
| `@buffer` | Full buffer (truncated >500 lines) | File path + code block |
| `@buffers` | All loaded file buffers | List with 3-line previews |
| `@visible` | Visible lines in all windows | File paths + code blocks |
| `@diagnostics` | `vim.diagnostic.get(buf)` | Severity, line, message list |
| `@quickfix` | `vim.fn.getqflist()` | File, line, col, text list |
| `@diff` | `git --no-pager diff` | Unified diff in code fence |

### Example resolved prompt

Input: `Explain @this`

Resolved:
```
Explain File: `src/auth.ts` (lines 21-35)
```typescript
export async function validateToken(token: string): Promise<boolean> {
  const decoded = jwt.verify(token, SECRET);
  return decoded !== null;
}
```
```

## File Reload

When pi edits files, Neovim detects changes via:
- `vim.o.autoread = true` (assumed/recommended)
- `FocusGained` + `BufEnter` autocmds run `checktime`
- This is the same proven approach opencode.nvim uses

## Phase 2: RPC Sidecar (Future)

A separate `pi --mode rpc` process alongside the terminal would enable:
- **Statusline**: streaming/idle indicator, model name, cost tracking
- **Structured file reload**: `tool_execution_end` events identify exactly which files changed
- **Extension UI**: pi extensions can request `select`/`confirm`/`input` — surface via `vim.ui.select`
- **Programmatic control**: model switching, compaction, session management from Neovim

The terminal would remain the primary display; RPC would add intelligence.
