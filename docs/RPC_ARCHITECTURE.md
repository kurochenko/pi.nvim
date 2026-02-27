# RPC Architecture Analysis

## Problem

pi.nvim currently injects keystrokes into pi's terminal via `chansend()` (bracketed
paste, Ctrl-C, Enter). This has several downsides:

1. **Bracketed paste auto-submits** — pi's TUI treats paste completion as a submit
   event, making it impossible to "just paste" text without triggering execution.
2. **Timing-dependent** — hardcoded delays (50ms, 500ms) between clear/paste/submit.
3. **Fragile** — Ctrl-C before every send clears user-typed content.
4. **No feedback channel** — we can't read pi's state, streaming output, or events.

opencode.nvim solves all of these by using opencode's built-in HTTP server. The
terminal is display-only; all communication flows through `curl` to
`localhost:<port>/tui/publish`.

Pi doesn't have an HTTP server in TUI mode, but it has a full **RPC mode**
(`pi --mode rpc`) with a JSON protocol over stdin/stdout that covers the same
capabilities.

---

## Architecture Options

### Option A: RPC-only with Neovim-native UI (recommended)

No terminal. Spawn `pi --mode rpc` as a subprocess. Build the chat experience
in Neovim buffers.

```
┌─────────────────────────┐     stdin (JSON)      ┌──────────────┐
│      Neovim buffers     │ ──────────────────────▶│              │
│  (chat, tools, status)  │                        │  pi --mode   │
│                         │ ◀──────────────────────│     rpc      │
│   lua/pi/rpc.lua        │     stdout (JSON)      │              │
└─────────────────────────┘                        └──────────────┘
```

**Sending a prompt:**
```json
{"type": "prompt", "message": "Explain lua/pi/init.lua:12-25"}
```

**Receiving streaming response:**
```json
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "This function..."}}
```

**Aborting:**
```json
{"type": "abort"}
```

#### What we'd build

| Component | Description | Complexity |
|-----------|-------------|------------|
| `lua/pi/rpc.lua` | Spawn `pi --mode rpc`, write JSON to stdin, parse JSON lines from stdout | Medium |
| `lua/pi/chat.lua` | Buffer that renders conversation (markdown, code blocks, tool calls) | High |
| `lua/pi/stream.lua` | Handle streaming deltas — append text as it arrives | Medium |
| `lua/pi/tools_display.lua` | Show tool execution (read, bash, edit) with expand/collapse | Medium |
| `lua/pi/status.lua` | Statusline component: model, thinking level, streaming state | Low |
| `lua/pi/session.lua` | Session management: new, continue, switch, fork | Medium |
| `lua/pi/model.lua` | Model picker (cycle_model, set_model, get_available_models) | Low |
| `lua/pi/permissions.lua` | Handle extension UI requests (select, confirm, input) | Medium |
| `lua/pi/init.lua` | Rewired public API: setup, ask, prompt, select, abort | Medium |

#### RPC commands we'd use

| Command | Purpose |
|---------|---------|
| `prompt` | Send user message (with `streamingBehavior` for queuing) |
| `steer` | Interrupt agent mid-run with new instruction |
| `follow_up` | Queue message for after agent finishes |
| `abort` | Cancel current operation |
| `get_state` | Model, thinking level, streaming status, session info |
| `get_messages` | Full conversation history (for initial render) |
| `set_model` / `cycle_model` | Model management |
| `set_thinking_level` / `cycle_thinking_level` | Thinking control |
| `compact` | Manual compaction |
| `new_session` / `switch_session` | Session management |
| `get_commands` | Extension commands for picker |
| `bash` | Execute shell command and add to context |
| `export_html` | Export session |

#### Events we'd handle

| Event | UI action |
|-------|-----------|
| `message_update` (text_delta) | Append text to chat buffer |
| `message_update` (thinking_delta) | Show in collapsible thinking block |
| `message_update` (toolcall_start/delta/end) | Show tool call being built |
| `tool_execution_start` | Show "Running bash: ls -la..." |
| `tool_execution_update` | Stream tool output |
| `tool_execution_end` | Mark tool complete, show result |
| `message_end` | Finalize message rendering |
| `agent_end` | Mark conversation as idle |
| `auto_compaction_start/end` | Show compaction indicator |
| `auto_retry_start/end` | Show retry indicator |
| `extension_ui_request` | Prompt user via vim.ui.select/input/confirm |

#### Pros
- **Zero typing lag** — terminal not involved
- **Full control** — native Neovim UI, themes, treesitter highlighting
- **Bidirectional** — read pi's state, react to events, handle permissions
- **No timing hacks** — structured JSON protocol, no chansend delays
- **Vim-native UX** — navigate chat with normal motions, yank code blocks, search

#### Cons
- **Large scope** — essentially building a chat UI from scratch
- **Markdown rendering** — need to render assistant output nicely (could use existing plugins like render-markdown.nvim)
- **No pi TUI features** — session tree navigator, model selector, settings UI all need reimplementation or delegation to extension commands
- **Maintenance burden** — must track pi RPC protocol changes

#### Effort estimate: **3-5 weeks** for feature parity with current plugin + basic chat UI

---

### Option B: Hybrid — TUI terminal + RPC sidecar

Keep pi's TUI in a terminal for direct interaction. Use a separate RPC process
for programmatic sends only. Session state is NOT shared.

```
┌──────────────┐                    ┌──────────────┐
│  pi terminal │  (user interacts)  │              │
│    (TUI)     │                    │  pi --mode   │
│              │                    │   rpc        │
└──────────────┘                    │ --no-session │
                                    └──────────────┘
        ▲                                  ▲
        │ display                          │ programmatic
        │                                  │ sends
        └──────────┐          ┌────────────┘
                   │          │
              ┌────┴──────────┴────┐
              │      Neovim        │
              │   lua/pi/init.lua  │
              └────────────────────┘
```

**Problem:** Two separate pi instances. The RPC process sends a prompt, gets a
response — but the TUI doesn't see it. The user sees pi's TUI and wonders why
nothing happened. We'd need to somehow relay the RPC response back to the TUI,
which isn't possible without TUI-side support.

**Workaround:** Use RPC `--no-session` for stateless analysis, and terminal
`chansend` for the TUI-integrated flow. Essentially two different modes.

#### Pros
- Keeps pi's full TUI for interactive use
- RPC adds a clean programmatic channel
- Incremental — can migrate features gradually

#### Cons
- **Split brain** — two pi instances, no shared state
- **Confusing UX** — some prompts go to TUI, some to RPC; responses appear in different places
- **Still need chansend** — for TUI-targeted sends, same timing issues remain
- **Double resource usage** — two LLM sessions

#### Verdict: **Not recommended** — the split-brain problem makes this worse than either pure approach.

---

### Option C: TUI terminal + chansend (current approach, improved)

Keep the current architecture but accept its limitations. Improve where possible.

#### Already done
- Retry limits on terminal startup
- Configurable timing
- Optional clear_before_send
- File reference via raw keystrokes for prompt_this

#### Further improvements possible
- **Detect pi readiness** — watch terminal output for pi's prompt character before sending
- **Use `TermRequest` autocmd** — like opencode.nvim does for initial render fix
- **Better abort** — double-escape with delay

#### Pros
- Already working
- Minimal code
- Full pi TUI experience
- Zero maintenance for UI rendering

#### Cons
- Can't paste multi-line text without auto-submit (pi TUI limitation)
- No feedback channel (can't read state, events)
- Timing-dependent
- Fragile keystroke injection

#### Verdict: **Good enough for v1**. Production-quality for the use cases it supports.

---

### Option D: Request pi add TUI server mode

Like opencode's `--port` flag — an HTTP/WebSocket server embedded in the TUI process.
This would allow direct communication with the running TUI without keystroke injection.

Pi's RPC protocol already has `tui.prompt.append` and `tui.command.execute` event
types (visible in opencode's client which reuses similar patterns). If pi exposed
these via a local server in TUI mode, we'd get the best of both worlds.

#### Verdict: **Out of our control**, but worth requesting upstream.

---

## Recommendation

### Short term (now): Stay on Option C

The current architecture works. The file-reference approach for `<leader>pp` is
clean. Named prompts auto-submit correctly. The typing lag is pi's TUI rendering
through Neovim's terminal, not our plugin.

### Medium term: Option A (RPC-native)

When the plugin needs to grow beyond "send prompts to a terminal", Option A is
the right path. The trigger points would be:

- Users want to see streaming responses in a Neovim buffer
- Users want to interact with tool calls (approve/reject)
- Users want model/thinking control from Neovim
- Users want session management from Neovim

### Implementation plan for Option A

#### Phase 1: RPC client (1 week)
- `lua/pi/rpc.lua` — spawn process, JSON encode/decode, request/response correlation
- `lua/pi/events.lua` — event dispatcher, subscribe/unsubscribe
- Basic tests with `pi --mode rpc --no-session`

#### Phase 2: Chat buffer (1-2 weeks)
- `lua/pi/chat.lua` — read-only buffer with conversation rendering
- Streaming text append (handle `text_delta` events)
- Markdown rendering (integrate with render-markdown.nvim or manual syntax)
- Tool call display (collapsible sections)
- Split layout: chat buffer + input buffer

#### Phase 3: Input and prompting (3-4 days)
- Rewrite `ask()`, `prompt()`, `select()` to use RPC
- Context resolution unchanged (reuse `lua/pi/context.lua`)
- Input via snacks.input or vim.ui.input (unchanged)

#### Phase 4: State and controls (3-4 days)
- Model picker (get_available_models → vim.ui.select → set_model)
- Thinking level toggle
- Session management (new, continue, switch)
- Statusline integration

#### Phase 5: Extension UI and polish (3-4 days)
- Handle `extension_ui_request` events (permissions, confirmations)
- Export session to HTML
- Health check updates
- Documentation

#### Phase 6: Terminal fallback (optional)
- Keep terminal module as opt-in fallback for users who prefer pi's native TUI
- Config option: `mode = "rpc"` (default) or `mode = "terminal"`

---

## Key differences from opencode.nvim

| Aspect | opencode.nvim | pi.nvim (proposed) |
|--------|--------------|-------------------|
| Transport | HTTP (curl to localhost:port) | stdin/stdout (JSON lines to subprocess) |
| Process | Connects to running server | Spawns and owns the process |
| Discovery | Finds opencode via pgrep + lsof | Manages lifecycle directly |
| Events | SSE (Server-Sent Events via HTTP) | JSON lines on stdout |
| Session | Server manages session | RPC process manages session |
| TUI | Separate terminal, display only | No TUI — Neovim IS the UI |

The stdin/stdout approach is actually **simpler** than opencode's HTTP+SSE+pgrep
discovery. We spawn one process, pipe JSON in, read JSON out. No port discovery,
no curl, no connection management.

---

## Files that change

### Rewritten
- `lua/pi/init.lua` — public API rewired to RPC
- `lua/pi/terminal.lua` — replaced by `rpc.lua` (kept as optional fallback)

### New
- `lua/pi/rpc.lua` — RPC client (spawn, send, receive)
- `lua/pi/events.lua` — event dispatcher
- `lua/pi/chat.lua` — chat buffer rendering
- `lua/pi/stream.lua` — streaming text handler
- `lua/pi/model.lua` — model management
- `lua/pi/session.lua` — session management

### Unchanged
- `lua/pi/config.lua` — add `mode` option, RPC-specific settings
- `lua/pi/context.lua` — reused as-is
- `lua/pi/health.lua` — add RPC process health check
- `plugin/pi.lua` — minimal changes (commands stay the same)
