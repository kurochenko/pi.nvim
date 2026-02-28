--- Chat buffer for rendering pi conversation.
--- Creates a scratch buffer with markdown highlighting for the conversation.
local config = require("pi.config")

local M = {}

---@type integer|nil Chat buffer number
M.buf = nil
---@type integer|nil Chat window id
M.win = nil

--- Whether auto-scroll is active (disabled when user scrolls up)
local auto_scroll = true

--- Current line count used for incremental append tracking
local append_line = 0

--- Track the last streaming block position for incremental updates
---@type { start_line: integer, content: string }|nil
local streaming_block = nil

-- =========================================================================
-- Highlight groups
-- =========================================================================

local function setup_highlights()
  vim.api.nvim_set_hl(0, "PiUser", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "PiAssistant", { default = true, link = "Function" })
  vim.api.nvim_set_hl(0, "PiThinking", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "PiTool", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "PiToolError", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "PiMeta", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "PiCost", { default = true, link = "Number" })
  vim.api.nvim_set_hl(0, "PiStreaming", { default = true, link = "WarningMsg" })
end

-- =========================================================================
-- Buffer management
-- =========================================================================

--- Get split size based on config.
---@return integer
local function split_size()
  local cfg = config.opts.rpc or {}
  local position = cfg.position or config.opts.terminal.position or "right"
  local size = cfg.size or config.opts.terminal.size or 0.4

  if position == "bottom" then
    return math.floor(vim.o.lines * size)
  else
    return math.floor(vim.o.columns * size)
  end
end

--- Get the position from config.
---@return string
local function get_position()
  local cfg = config.opts.rpc or {}
  return cfg.position or config.opts.terminal.position or "right"
end

--- Create the chat buffer if it doesn't exist.
---@return integer bufnr
local function ensure_buffer()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end

  M.buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch

  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].modifiable = false

  -- Use a custom filetype to avoid triggering render-markdown.nvim and
  -- treesitter markdown parser, which causes SIGKILL in interactive mode
  -- with certain plugin configurations (render-markdown.nvim + treesitter
  -- markdown_inline injection = infinite loop on scratch buffers).
  vim.bo[M.buf].filetype = "pi_chat"

  vim.api.nvim_buf_set_name(M.buf, "pi://chat")

  -- Buffer-local keymaps
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = M.buf, silent = true, desc = "Close Pi chat" })

  -- Track scroll position to disable auto-scroll when user scrolls up
  local group = vim.api.nvim_create_augroup("PiChatScroll", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = M.buf,
    callback = function()
      if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
      end
      local total = vim.api.nvim_buf_line_count(M.buf)
      local cursor = vim.api.nvim_win_get_cursor(M.win)
      -- If cursor is within 3 lines of the bottom, re-enable auto-scroll
      auto_scroll = (total - cursor[1]) <= 3
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = M.buf,
    callback = function()
      M.buf = nil
      M.win = nil
    end,
  })

  append_line = 0
  streaming_block = nil

  return M.buf
end

--- Open the chat window.
---@param opts? { enter?: boolean }
function M.open(opts)
  opts = opts or {}
  local enter = opts.enter or false

  setup_highlights()
  local buf = ensure_buffer()

  -- Already visible
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    if enter then
      vim.api.nvim_set_current_win(M.win)
    end
    return
  end

  local pos = get_position()
  local size = split_size()
  local source_win = vim.api.nvim_get_current_win()

  if pos == "bottom" then
    vim.cmd("botright " .. size .. "split")
  elseif pos == "left" then
    vim.cmd("topleft " .. size .. "vsplit")
  else -- right
    vim.cmd("botright " .. size .. "vsplit")
  end

  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, buf)

  -- Window options
  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].signcolumn = "no"
  vim.wo[M.win].foldmethod = "manual"
  vim.wo[M.win].foldenable = true
  vim.wo[M.win].conceallevel = 2
  vim.wo[M.win].concealcursor = "nc"

  if not enter then
    vim.api.nvim_set_current_win(source_win)
  end

  -- Scroll to bottom
  M.scroll_to_bottom()
end

--- Close the chat window (keeps buffer alive).
function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, false)
  end
  M.win = nil
end

--- Toggle the chat window.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Check if the chat window is visible.
---@return boolean
function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Scroll the chat window to the bottom.
function M.scroll_to_bottom()
  if not M.is_open() or not M.buf then
    return
  end
  local total = vim.api.nvim_buf_line_count(M.buf)
  pcall(vim.api.nvim_win_set_cursor, M.win, { total, 0 })
end

-- =========================================================================
-- Content writing
-- =========================================================================

--- Write lines to the buffer (replacing all content).
---@param lines string[]
local function set_lines(lines)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  append_line = #lines
end

--- Append lines to the end of the buffer.
---@param lines string[]
function M.append(lines)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  append_line = vim.api.nvim_buf_line_count(M.buf)

  if auto_scroll then
    M.scroll_to_bottom()
  end
end

--- Replace lines from start_line to end of buffer.
---@param start_line integer 0-indexed
---@param lines string[]
function M.replace_from(start_line, lines)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, start_line, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  append_line = vim.api.nvim_buf_line_count(M.buf)

  if auto_scroll then
    M.scroll_to_bottom()
  end
end

--- Clear all content.
function M.clear()
  set_lines({ "" })
  append_line = 0
  streaming_block = nil
  auto_scroll = true
end

-- =========================================================================
-- Message rendering
-- =========================================================================

--- Format a cost value.
---@param cost number
---@return string
local function format_cost(cost)
  if cost < 0.01 then
    return string.format("$%.4f", cost)
  end
  return string.format("$%.2f", cost)
end

--- Render a user message to lines.
---@param msg table UserMessage
---@return string[]
local function render_user_message(msg)
  local lines = { "## 👤 You", "" }
  local content = msg.content
  if type(content) == "string" then
    for _, line in ipairs(vim.split(content, "\n")) do
      lines[#lines + 1] = line
    end
  elseif type(content) == "table" then
    for _, block in ipairs(content) do
      if block.type == "text" then
        for _, line in ipairs(vim.split(block.text, "\n")) do
          lines[#lines + 1] = line
        end
      elseif block.type == "image" then
        lines[#lines + 1] = "*[image attached]*"
      end
    end
  end
  lines[#lines + 1] = ""
  return lines
end

--- Render an assistant message to lines.
---@param msg table AssistantMessage
---@return string[]
local function render_assistant_message(msg)
  local lines = {}

  -- Header with model info
  local model_name = msg.model or (msg.provider or "")
  local header = "## 🤖 Pi"
  if model_name ~= "" then
    header = header .. " *(" .. model_name .. ")*"
  end
  lines[#lines + 1] = header
  lines[#lines + 1] = ""

  -- Content blocks
  if msg.content then
    for _, block in ipairs(msg.content) do
      if block.type == "thinking" and block.thinking and block.thinking ~= "" then
        lines[#lines + 1] = "<details>"
        lines[#lines + 1] = "<summary>💭 Thinking</summary>"
        lines[#lines + 1] = ""
        for _, line in ipairs(vim.split(block.thinking, "\n")) do
          lines[#lines + 1] = "> " .. line
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "</details>"
        lines[#lines + 1] = ""
      elseif block.type == "text" and block.text then
        for _, line in ipairs(vim.split(block.text, "\n")) do
          lines[#lines + 1] = line
        end
        lines[#lines + 1] = ""
      elseif block.type == "toolCall" then
        lines[#lines + 1] = string.format("**🔧 Tool: %s** `%s`", block.name or "unknown", block.id or "")
        if block.arguments then
          local args_str = type(block.arguments) == "string" and block.arguments
            or vim.json.encode(block.arguments)
          -- Truncate long args
          if #args_str > 200 then
            args_str = args_str:sub(1, 200) .. "..."
          end
          lines[#lines + 1] = "```json"
          lines[#lines + 1] = args_str
          lines[#lines + 1] = "```"
        end
        lines[#lines + 1] = ""
      end
    end
  end

  -- Cost/usage footer
  if msg.usage and msg.usage.cost then
    local cost = msg.usage.cost
    local total = cost.total or 0
    if total > 0 then
      lines[#lines + 1] = string.format(
        "*tokens: %d in / %d out | cost: %s*",
        msg.usage.input or 0,
        msg.usage.output or 0,
        format_cost(total)
      )
      lines[#lines + 1] = ""
    end
  end

  return lines
end

--- Render a tool result message to lines.
---@param msg table ToolResultMessage
---@return string[]
local function render_tool_result(msg)
  local lines = {}
  local icon = msg.isError and "❌" or "✅"
  lines[#lines + 1] = string.format("**%s Result: %s** `%s`", icon, msg.toolName or "tool", msg.toolCallId or "")
  lines[#lines + 1] = ""

  if msg.content then
    for _, block in ipairs(msg.content) do
      if block.type == "text" and block.text then
        local text = block.text
        -- Truncate very long outputs
        local text_lines = vim.split(text, "\n")
        if #text_lines > 50 then
          local truncated = {}
          for i = 1, 25 do
            truncated[#truncated + 1] = text_lines[i]
          end
          truncated[#truncated + 1] = ""
          truncated[#truncated + 1] = string.format("*... (%d lines truncated) ...*", #text_lines - 50)
          truncated[#truncated + 1] = ""
          for i = #text_lines - 24, #text_lines do
            truncated[#truncated + 1] = text_lines[i]
          end
          text = table.concat(truncated, "\n")
        end
        lines[#lines + 1] = "```"
        for _, line in ipairs(vim.split(text, "\n")) do
          lines[#lines + 1] = line
        end
        lines[#lines + 1] = "```"
      end
    end
  end

  lines[#lines + 1] = ""
  return lines
end

--- Render a bash execution message to lines.
---@param msg table BashExecutionMessage
---@return string[]
local function render_bash_execution(msg)
  local lines = {}
  local icon = (msg.exitCode == 0) and "✅" or "❌"
  lines[#lines + 1] = string.format("**%s Bash** `%s`", icon, msg.command or "")
  if msg.output and msg.output ~= "" then
    lines[#lines + 1] = "```"
    for _, line in ipairs(vim.split(msg.output, "\n")) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = "```"
  end
  lines[#lines + 1] = ""
  return lines
end

--- Render a single message to lines based on its role.
---@param msg table AgentMessage
---@return string[]
local function render_message(msg)
  local role = msg.role
  if role == "user" then
    return render_user_message(msg)
  elseif role == "assistant" then
    return render_assistant_message(msg)
  elseif role == "toolResult" then
    return render_tool_result(msg)
  elseif role == "bashExecution" then
    return render_bash_execution(msg)
  elseif role == "system_info" then
    local text = type(msg.content) == "string" and msg.content or ""
    return { text, "" }
  else
    return { string.format("*[%s message]*", role or "unknown"), "" }
  end
end

--- Render all messages (full conversation).
---@param messages table[] Array of AgentMessage
function M.render_messages(messages)
  local all_lines = {}
  for _, msg in ipairs(messages) do
    local msg_lines = render_message(msg)
    for _, line in ipairs(msg_lines) do
      all_lines[#all_lines + 1] = line
    end
    -- Separator between messages
    all_lines[#all_lines + 1] = "---"
    all_lines[#all_lines + 1] = ""
  end

  set_lines(all_lines)
  auto_scroll = true
  M.scroll_to_bottom()
end

-- =========================================================================
-- Streaming support
-- =========================================================================

--- Begin a new streaming assistant message.
---@param model_name? string
function M.begin_streaming(model_name)
  local header = "## 🤖 Pi"
  if model_name and model_name ~= "" then
    header = header .. " *(" .. model_name .. ")*"
  end

  M.append({ "---", "", header, "" })

  streaming_block = {
    start_line = vim.api.nvim_buf_line_count(M.buf),
    content = "",
  }
end

--- Append streaming thinking text.
---@param text string Delta text
function M.append_thinking(text)
  if not streaming_block then
    return
  end

  -- We accumulate thinking in a blockquote
  streaming_block.content = streaming_block.content .. text
  local quoted_lines = {}
  quoted_lines[#quoted_lines + 1] = "<details open>"
  quoted_lines[#quoted_lines + 1] = "<summary>💭 Thinking...</summary>"
  quoted_lines[#quoted_lines + 1] = ""
  for _, line in ipairs(vim.split(streaming_block.content, "\n")) do
    quoted_lines[#quoted_lines + 1] = "> " .. line
  end
  quoted_lines[#quoted_lines + 1] = ""
  quoted_lines[#quoted_lines + 1] = "</details>"
  quoted_lines[#quoted_lines + 1] = ""

  M.replace_from(streaming_block.start_line - 1, quoted_lines)
end

--- Signal that thinking is complete and text output begins.
function M.end_thinking()
  if not streaming_block then
    return
  end
  -- Finalize the thinking block and reset for text content
  streaming_block.start_line = vim.api.nvim_buf_line_count(M.buf) + 1
  streaming_block.content = ""
end

--- Append streaming text delta.
---@param text string Delta text to append
function M.append_text(text)
  if not streaming_block then
    return
  end

  streaming_block.content = streaming_block.content .. text
  local text_lines = vim.split(streaming_block.content, "\n")

  M.replace_from(streaming_block.start_line - 1, text_lines)
end

--- End the streaming message.
---@param final_message? table The complete AssistantMessage
function M.end_streaming(final_message)
  if not streaming_block then
    return
  end

  -- Add cost footer if available
  if final_message and final_message.usage and final_message.usage.cost then
    local cost = final_message.usage.cost
    local total = cost.total or 0
    if total > 0 then
      M.append({
        "",
        string.format(
          "*tokens: %d in / %d out | cost: %s*",
          final_message.usage.input or 0,
          final_message.usage.output or 0,
          format_cost(total)
        ),
      })
    end
  end

  M.append({ "", "" })
  streaming_block = nil
end

--- Append a user message to the chat.
---@param text string
function M.append_user_message(text)
  local lines = render_user_message({ role = "user", content = text })
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""
  M.append(lines)
end

--- Append a tool execution start indicator.
---@param tool_call_id string
---@param tool_name string
---@param args? table
function M.append_tool_start(tool_call_id, tool_name, args)
  local lines = { string.format("**🔧 Running %s...**", tool_name) }

  if args then
    if tool_name == "bash" and args.command then
      lines[#lines + 1] = "```bash"
      lines[#lines + 1] = args.command
      lines[#lines + 1] = "```"
    elseif (tool_name == "read" or tool_name == "edit" or tool_name == "write") and args.path then
      lines[#lines + 1] = string.format("`%s`", args.path)
    end
  end

  lines[#lines + 1] = ""
  M.append(lines)

  -- Track start position for live updates (bash)
  if tool_name == "bash" and tool_call_id then
    tool_progress[tool_call_id] = {
      start_line = vim.api.nvim_buf_line_count(M.buf) - 1,
    }
  end
end

--- Track tool execution progress for live updates.
---@type table<string, { start_line: integer }>
local tool_progress = {}

--- Update tool execution progress (replaces output in-place for bash).
---@param tool_call_id string
---@param tool_name string
---@param partial_result? table
function M.update_tool_progress(tool_call_id, tool_name, partial_result)
  if not partial_result or not partial_result.content then
    return
  end

  -- Only do live updates for bash (others are quick)
  if tool_name ~= "bash" then
    return
  end

  -- Get the text content from the partial result
  local text = ""
  for _, block in ipairs(partial_result.content) do
    if block.type == "text" and block.text then
      text = block.text
    end
  end

  if text == "" then
    return
  end

  local track = tool_progress[tool_call_id]
  if not track then
    return
  end

  -- Replace from the tracked start line with the accumulated output
  local output_lines = vim.split(text, "\n")
  -- Truncate for display
  if #output_lines > 50 then
    local truncated = {}
    for i = #output_lines - 49, #output_lines do
      truncated[#truncated + 1] = output_lines[i]
    end
    output_lines = truncated
  end

  local display = { "```" }
  for _, line in ipairs(output_lines) do
    display[#display + 1] = line
  end
  display[#display + 1] = "```"
  display[#display + 1] = ""

  M.replace_from(track.start_line, display)
end

--- Append tool execution result.
---@param tool_call_id string
---@param tool_name string
---@param result? table
---@param is_error boolean
function M.append_tool_result(tool_call_id, tool_name, result, is_error)
  -- Clean up progress tracking
  if tool_call_id then
    tool_progress[tool_call_id] = nil
  end

  local lines = {}
  local icon = is_error and "❌" or "✅"
  lines[#lines + 1] = string.format("**%s %s done**", icon, tool_name)

  if result and result.content then
    for _, block in ipairs(result.content) do
      if block.type == "text" and block.text and block.text ~= "" then
        local text_lines = vim.split(block.text, "\n")
        if #text_lines > 30 then
          lines[#lines + 1] = "<details>"
          lines[#lines + 1] = string.format("<summary>Output (%d lines)</summary>", #text_lines)
          lines[#lines + 1] = ""
          lines[#lines + 1] = "```"
          for i = 1, math.min(30, #text_lines) do
            lines[#lines + 1] = text_lines[i]
          end
          if #text_lines > 30 then
            lines[#lines + 1] = string.format("... (%d more lines)", #text_lines - 30)
          end
          lines[#lines + 1] = "```"
          lines[#lines + 1] = "</details>"
        else
          lines[#lines + 1] = "```"
          for _, line in ipairs(text_lines) do
            lines[#lines + 1] = line
          end
          lines[#lines + 1] = "```"
        end
      end
    end
  end

  lines[#lines + 1] = ""
  M.append(lines)
end

return M
