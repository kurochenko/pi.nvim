--- Event dispatcher and state tracking for pi RPC events.
--- Subscribes to rpc.lua events and maintains derived agent state.
--- Emits Neovim User autocmds for external integration.
local M = {}

---@class pi.AgentState
---@field is_streaming boolean Agent is currently processing
---@field is_compacting boolean Auto-compaction in progress
---@field is_retrying boolean Auto-retry in progress
---@field model table|nil Current model object
---@field thinking_level string|nil Current thinking level
---@field session_file string|nil Path to session file
---@field session_id string|nil Session UUID
---@field session_name string|nil Display name
---@field message_count integer Number of messages in session
---@field pending_message_count integer Queued messages
---@field steering_mode string "all" or "one-at-a-time"
---@field follow_up_mode string "all" or "one-at-a-time"
---@field auto_compaction_enabled boolean
---@field rpc_status string "stopped"|"starting"|"ready"|"dead"

---@type pi.AgentState
local agent_state = {
  is_streaming = false,
  is_compacting = false,
  is_retrying = false,
  model = nil,
  thinking_level = nil,
  session_file = nil,
  session_id = nil,
  session_name = nil,
  message_count = 0,
  pending_message_count = 0,
  steering_mode = "one-at-a-time",
  follow_up_mode = "one-at-a-time",
  auto_compaction_enabled = true,
  rpc_status = "stopped",
}

--- Subscriber storage: event_type → callbacks
---@type table<string, fun(event: table)[]>
local subscribers = {}

--- Wildcard subscribers
---@type fun(event: table)[]
local wildcard_subscribers = {}

--- RPC listener unsubscribe functions
---@type fun()[]
local rpc_unsubs = {}

--- Emit a Neovim User autocmd for the event.
---@param event_type string
---@param data table
local function emit_autocmd(event_type, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "PiEvent:" .. event_type,
    data = data,
  })
end

--- Dispatch event to subscribers.
---@param event table
local function dispatch(event)
  local event_type = event.type
  if not event_type then
    return
  end

  -- Type-specific subscribers
  local type_subs = subscribers[event_type]
  if type_subs then
    for _, cb in ipairs(type_subs) do
      local ok, err = pcall(cb, event)
      if not ok then
        vim.notify("Pi events: subscriber error for " .. event_type .. ": " .. tostring(err), vim.log.levels.DEBUG)
      end
    end
  end

  -- Wildcard subscribers
  for _, cb in ipairs(wildcard_subscribers) do
    local ok, err = pcall(cb, event)
    if not ok then
      vim.notify("Pi events: wildcard subscriber error: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end

  -- Neovim autocmd
  emit_autocmd(event_type, event)
end

-- =========================================================================
-- State update handlers
-- =========================================================================

--- Update state from get_state response or rpc_ready event.
---@param data table
local function update_from_state(data)
  if data.model then
    agent_state.model = data.model
  end
  if data.thinkingLevel then
    agent_state.thinking_level = data.thinkingLevel
  end
  if data.isStreaming ~= nil then
    agent_state.is_streaming = data.isStreaming
  end
  if data.isCompacting ~= nil then
    agent_state.is_compacting = data.isCompacting
  end
  if data.sessionFile then
    agent_state.session_file = data.sessionFile
  end
  if data.sessionId then
    agent_state.session_id = data.sessionId
  end
  if data.sessionName then
    agent_state.session_name = data.sessionName
  end
  if data.messageCount then
    agent_state.message_count = data.messageCount
  end
  if data.pendingMessageCount then
    agent_state.pending_message_count = data.pendingMessageCount
  end
  if data.steeringMode then
    agent_state.steering_mode = data.steeringMode
  end
  if data.followUpMode then
    agent_state.follow_up_mode = data.followUpMode
  end
  if data.autoCompactionEnabled ~= nil then
    agent_state.auto_compaction_enabled = data.autoCompactionEnabled
  end
end

--- Event handlers that update agent_state.
---@type table<string, fun(event: table)>
local state_handlers = {
  rpc_ready = function(event)
    agent_state.rpc_status = "ready"
    if event.data then
      update_from_state(event.data)
    end
  end,

  rpc_process_exit = function(_)
    agent_state.rpc_status = "dead"
    agent_state.is_streaming = false
    agent_state.is_compacting = false
    agent_state.is_retrying = false
  end,

  agent_start = function(_)
    agent_state.is_streaming = true
  end,

  agent_end = function(event)
    agent_state.is_streaming = false
    if event.messages then
      agent_state.message_count = agent_state.message_count + #event.messages
    end
  end,

  auto_compaction_start = function(_)
    agent_state.is_compacting = true
  end,

  auto_compaction_end = function(_)
    agent_state.is_compacting = false
  end,

  auto_retry_start = function(_)
    agent_state.is_retrying = true
  end,

  auto_retry_end = function(_)
    agent_state.is_retrying = false
  end,
}

-- =========================================================================
-- Public API
-- =========================================================================

--- Subscribe to a specific event type.
---@param event_type string
---@param callback fun(event: table)
---@return fun() unsubscribe function
function M.on(event_type, callback)
  if not subscribers[event_type] then
    subscribers[event_type] = {}
  end
  table.insert(subscribers[event_type], callback)

  return function()
    local subs = subscribers[event_type]
    if subs then
      for i, cb in ipairs(subs) do
        if cb == callback then
          table.remove(subs, i)
          return
        end
      end
    end
  end
end

--- Subscribe to all events.
---@param callback fun(event: table)
---@return fun() unsubscribe function
function M.on_any(callback)
  table.insert(wildcard_subscribers, callback)

  return function()
    for i, cb in ipairs(wildcard_subscribers) do
      if cb == callback then
        table.remove(wildcard_subscribers, i)
        return
      end
    end
  end
end

--- Get current agent state (read-only copy).
---@return pi.AgentState
function M.get_state()
  return vim.deepcopy(agent_state)
end

--- Get a reference to the live state (for statusline — avoid copies).
---@return pi.AgentState
function M.get_state_ref()
  return agent_state
end

--- Refresh state from the RPC process.
---@param callback? fun(state: pi.AgentState)
function M.refresh_state(callback)
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    if callback then
      callback(agent_state)
    end
    return
  end

  rpc.request({ type = "get_state" }, function(response)
    if response.success and response.data then
      update_from_state(response.data)
    end
    if callback then
      callback(agent_state)
    end
  end)
end

--- Connect to rpc.lua and start receiving events.
function M.connect()
  M.disconnect() -- Clean up any previous connections

  local rpc = require("pi.rpc")

  -- Subscribe to all RPC events and dispatch through our system
  local unsub = rpc.on_any(function(event)
    -- Update state first
    local handler = state_handlers[event.type]
    if handler then
      handler(event)
    end
    -- Then dispatch to subscribers
    dispatch(event)
  end)
  table.insert(rpc_unsubs, unsub)

  agent_state.rpc_status = rpc.get_status()
end

--- Disconnect from rpc.lua events.
function M.disconnect()
  for _, unsub in ipairs(rpc_unsubs) do
    unsub()
  end
  rpc_unsubs = {}
end

--- Remove all subscribers.
function M.clear()
  subscribers = {}
  wildcard_subscribers = {}
  M.disconnect()
end

return M
