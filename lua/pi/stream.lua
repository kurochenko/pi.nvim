--- Streaming text handler for pi RPC events.
--- Subscribes to message_update events and drives chat buffer updates
--- for real-time text/thinking/tool call rendering.
local M = {}

--- Internal state for the current streaming message
---@class pi.Stream.State
---@field active boolean Currently streaming
---@field phase "idle"|"thinking"|"text"|"toolcall" What kind of content is streaming
---@field content_index integer Current contentIndex being streamed
---@field model_name string|nil Model name for the header
---@field final_message table|nil Last known message state

---@type pi.Stream.State
local stream_state = {
  active = false,
  phase = "idle",
  content_index = -1,
  model_name = nil,
  final_message = nil,
}

--- Event unsubscribe functions
---@type fun()[]
local unsubs = {}

--- Reset streaming state.
local function reset()
  stream_state.active = false
  stream_state.phase = "idle"
  stream_state.content_index = -1
  stream_state.model_name = nil
  stream_state.final_message = nil
end

-- =========================================================================
-- Event handlers
-- =========================================================================

--- Handle agent_start: prepare for streaming.
---@param _ table
local function on_agent_start(_)
  reset()
  stream_state.active = true
end

--- Handle message_start: begin a new message in the chat.
---@param event table
local function on_message_start(event)
  local msg = event.message
  if not msg then
    return
  end

  local chat = require("pi.chat")

  if msg.role == "user" then
    -- Render user message in chat
    local content = msg.content
    if type(content) == "string" then
      chat.append_user_message(content)
    elseif type(content) == "table" then
      local text_parts = {}
      for _, block in ipairs(content) do
        if block.type == "text" then
          text_parts[#text_parts + 1] = block.text
        end
      end
      chat.append_user_message(table.concat(text_parts, "\n"))
    end
  elseif msg.role == "assistant" then
    stream_state.model_name = msg.model
    stream_state.content_index = -1
    stream_state.phase = "idle"
    chat.begin_streaming(msg.model)
  end
end

--- Handle message_update: process streaming deltas.
---@param event table
local function on_message_update(event)
  if not stream_state.active then
    return
  end

  local delta = event.assistantMessageEvent
  if not delta then
    return
  end

  local chat = require("pi.chat")
  local delta_type = delta.type

  -- Track final message state
  stream_state.final_message = event.message

  -- Thinking deltas
  if delta_type == "thinking_start" then
    stream_state.phase = "thinking"
    stream_state.content_index = delta.contentIndex or 0
  elseif delta_type == "thinking_delta" then
    if delta.delta then
      chat.append_thinking(delta.delta)
    end
  elseif delta_type == "thinking_end" then
    chat.end_thinking()
    stream_state.phase = "idle"

  -- Text deltas
  elseif delta_type == "text_start" then
    if stream_state.phase == "thinking" then
      chat.end_thinking()
    end
    stream_state.phase = "text"
    stream_state.content_index = delta.contentIndex or 0
  elseif delta_type == "text_delta" then
    if delta.delta then
      chat.append_text(delta.delta)
    end
  elseif delta_type == "text_end" then
    -- Text block complete, but message may continue with more blocks
    stream_state.phase = "idle"

  -- Tool call deltas
  elseif delta_type == "toolcall_start" then
    stream_state.phase = "toolcall"
    stream_state.content_index = delta.contentIndex or 0
  elseif delta_type == "toolcall_delta" then
    -- Tool call args streaming — we'll display on toolcall_end
  elseif delta_type == "toolcall_end" then
    stream_state.phase = "idle"
    -- toolcall_end includes the full toolCall object
    if delta.toolCall then
      chat.append({
        "",
        string.format("**🔧 Tool: %s**", delta.toolCall.name or "unknown"),
        "",
      })
    end

  -- Done/error
  elseif delta_type == "done" then
    -- Message generation complete
  elseif delta_type == "error" then
    local err_msg = ""
    if event.message and event.message.errorMessage then
      err_msg = event.message.errorMessage
    end
    chat.append({ "", "**❌ Error:** " .. err_msg, "" })
  end
end

--- Handle message_end: finalize the message.
---@param event table
local function on_message_end(event)
  local msg = event.message
  if not msg then
    return
  end

  if msg.role == "assistant" then
    local chat = require("pi.chat")
    chat.end_streaming(msg)
  end
end

--- Handle tool_execution_start.
---@param event table
local function on_tool_exec_start(event)
  local chat = require("pi.chat")
  chat.append_tool_start(event.toolCallId or "", event.toolName or "tool", event.args)
end

--- Handle tool_execution_update.
---@param event table
local function on_tool_exec_update(event)
  local chat = require("pi.chat")
  chat.update_tool_progress(event.toolCallId or "", event.toolName or "tool", event.partialResult)
end

--- Handle tool_execution_end.
---@param event table
local function on_tool_exec_end(event)
  local chat = require("pi.chat")
  chat.append_tool_result(event.toolCallId or "", event.toolName or "tool", event.result, event.isError or false)

  -- Trigger buffer reload for file-editing tools
  if not event.isError then
    local tool = event.toolName or ""
    if tool == "edit" or tool == "write" then
      vim.schedule(function()
        pcall(vim.cmd, "checktime")
      end)
    end
  end
end

--- Handle agent_end: streaming complete.
---@param _ table
local function on_agent_end(_)
  reset()
end

--- Handle auto_compaction_start.
---@param event table
local function on_compaction_start(event)
  local chat = require("pi.chat")
  local reason = event.reason or "threshold"
  chat.append({ "", string.format("*⏳ Auto-compacting context (%s)...*", reason), "" })
end

--- Handle auto_compaction_end.
---@param event table
local function on_compaction_end(event)
  local chat = require("pi.chat")
  if event.aborted then
    chat.append({ "*Compaction aborted*", "" })
  elseif event.result then
    local before = event.result.tokensBefore or 0
    chat.append({ string.format("*✅ Compacted (%d tokens before)*", before), "" })
  end
end

--- Handle auto_retry_start.
---@param event table
local function on_retry_start(event)
  local chat = require("pi.chat")
  chat.append({
    "",
    string.format(
      "*🔄 Retrying (attempt %d/%d, waiting %dms)...*",
      event.attempt or 0,
      event.maxAttempts or 0,
      event.delayMs or 0
    ),
    "",
  })
end

--- Handle auto_retry_end.
---@param event table
local function on_retry_end(event)
  local chat = require("pi.chat")
  if event.success then
    chat.append({ "*✅ Retry succeeded*", "" })
  else
    chat.append({ string.format("*❌ Retry failed: %s*", event.finalError or "unknown"), "" })
  end
end

-- =========================================================================
-- Public API
-- =========================================================================

--- Connect to the event system and start handling streaming.
function M.connect()
  M.disconnect()

  local events = require("pi.events")

  unsubs[#unsubs + 1] = events.on("agent_start", on_agent_start)
  unsubs[#unsubs + 1] = events.on("message_start", on_message_start)
  unsubs[#unsubs + 1] = events.on("message_update", on_message_update)
  unsubs[#unsubs + 1] = events.on("message_end", on_message_end)
  unsubs[#unsubs + 1] = events.on("tool_execution_start", on_tool_exec_start)
  unsubs[#unsubs + 1] = events.on("tool_execution_update", on_tool_exec_update)
  unsubs[#unsubs + 1] = events.on("tool_execution_end", on_tool_exec_end)
  unsubs[#unsubs + 1] = events.on("agent_end", on_agent_end)
  unsubs[#unsubs + 1] = events.on("auto_compaction_start", on_compaction_start)
  unsubs[#unsubs + 1] = events.on("auto_compaction_end", on_compaction_end)
  unsubs[#unsubs + 1] = events.on("auto_retry_start", on_retry_start)
  unsubs[#unsubs + 1] = events.on("auto_retry_end", on_retry_end)
end

--- Disconnect from the event system.
function M.disconnect()
  for _, unsub in ipairs(unsubs) do
    unsub()
  end
  unsubs = {}
  reset()
end

--- Check if currently streaming.
---@return boolean
function M.is_streaming()
  return stream_state.active
end

return M
