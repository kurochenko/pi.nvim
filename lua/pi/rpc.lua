--- RPC client for pi coding agent.
--- Spawns `pi --mode rpc` as a subprocess and communicates via JSON over stdin/stdout.
local config = require("pi.config")

local M = {}

---@class pi.Rpc.State
---@field job_id integer|nil vim.fn.jobstart channel id
---@field status "stopped"|"starting"|"ready"|"dead" Process state
---@field pending table<string, fun(response: table)> Request ID → callback
---@field listeners table<string, fun(event: table)[]> Event type → callbacks
---@field wildcard_listeners fun(event: table)[] Listen to all events
---@field request_counter integer Auto-incrementing request ID
---@field line_buffer string Partial line buffer for stdout

---@type pi.Rpc.State
local state = {
  job_id = nil,
  status = "stopped",
  pending = {},
  listeners = {},
  wildcard_listeners = {},
  request_counter = 0,
  line_buffer = "",
}

--- Generate a unique request ID.
---@return string
local function next_id()
  state.request_counter = state.request_counter + 1
  return "nvim-pi-" .. state.request_counter
end

--- Build the command args for pi --mode rpc.
---@return string[]
local function build_cmd()
  local cfg = config.opts.rpc or {}
  local cmd = cfg.cmd or config.opts.terminal.cmd or "pi"
  local args = { cmd, "--mode", "rpc" }

  if cfg.continue_session ~= false then
    args[#args + 1] = "-c"
  end

  -- Append any extra args
  if cfg.args then
    for _, arg in ipairs(cfg.args) do
      args[#args + 1] = arg
    end
  end

  return args
end

--- Process a single JSON line from stdout.
---@param line string
local function process_line(line)
  if line == "" then
    return
  end

  local ok, data = pcall(vim.json.decode, line)
  if not ok then
    vim.schedule(function()
      vim.notify("Pi RPC: failed to parse JSON: " .. line:sub(1, 100), vim.log.levels.DEBUG)
    end)
    return
  end

  -- If it's a response to a pending request, invoke callback
  if data.type == "response" and data.id and state.pending[data.id] then
    local cb = state.pending[data.id]
    state.pending[data.id] = nil
    vim.schedule(function()
      cb(data)
    end)
    return
  end

  -- Dispatch event to type-specific listeners
  local event_type = data.type
  if event_type then
    local type_listeners = state.listeners[event_type]
    if type_listeners then
      for _, cb in ipairs(type_listeners) do
        vim.schedule(function()
          cb(data)
        end)
      end
    end
  end

  -- Dispatch to wildcard listeners
  for _, cb in ipairs(state.wildcard_listeners) do
    vim.schedule(function()
      cb(data)
    end)
  end
end

--- Handle stdout data from the subprocess.
--- Data arrives as a list of strings (may contain partial lines).
---@param _ integer channel id (unused)
---@param data string[]
local function on_stdout(_, data)
  if not data then
    return
  end

  for i, chunk in ipairs(data) do
    if i == 1 then
      -- First chunk continues the previous partial line
      state.line_buffer = state.line_buffer .. chunk
    else
      -- Process the completed line from previous iteration
      process_line(state.line_buffer)
      state.line_buffer = chunk
    end
  end

  -- If the last element is "", it means the data ended with \n
  -- and line_buffer is now "" (ready for next batch)
  -- If not, line_buffer holds a partial line waiting for more data
end

--- Handle stderr data from the subprocess.
---@param _ integer
---@param data string[]
local function on_stderr(_, data)
  if not data then
    return
  end
  for _, line in ipairs(data) do
    if line ~= "" then
      vim.schedule(function()
        vim.notify("Pi RPC stderr: " .. line, vim.log.levels.DEBUG)
      end)
    end
  end
end

--- Handle process exit.
---@param _ integer
---@param exit_code integer
local function on_exit(_, exit_code)
  local was_ready = state.status == "ready" or state.status == "starting"
  state.job_id = nil
  state.status = "dead"
  state.line_buffer = ""

  -- Fail all pending requests
  for id, cb in pairs(state.pending) do
    state.pending[id] = nil
    vim.schedule(function()
      cb({ type = "response", id = id, success = false, error = "Process exited with code " .. exit_code })
    end)
  end

  vim.schedule(function()
    -- Dispatch a synthetic event for listeners
    local exit_event = { type = "rpc_process_exit", exit_code = exit_code }
    for _, cb in ipairs(state.wildcard_listeners) do
      cb(exit_event)
    end
    local exit_listeners = state.listeners["rpc_process_exit"]
    if exit_listeners then
      for _, cb in ipairs(exit_listeners) do
        cb(exit_event)
      end
    end

    if was_ready and exit_code ~= 0 then
      vim.notify(string.format("Pi RPC: process exited unexpectedly (code %d)", exit_code), vim.log.levels.WARN)
    end
  end)
end

--- Start the RPC subprocess.
---@param opts? { on_ready?: fun() }
function M.start(opts)
  opts = opts or {}

  if state.status == "ready" or state.status == "starting" then
    if opts.on_ready then
      opts.on_ready()
    end
    return
  end

  state.status = "starting"
  state.line_buffer = ""
  state.request_counter = 0
  state.pending = {}

  local cmd = build_cmd()

  state.job_id = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if state.job_id <= 0 then
    state.status = "dead"
    vim.notify("Pi RPC: failed to start subprocess: " .. table.concat(cmd, " "), vim.log.levels.ERROR)
    return
  end

  -- Probe readiness with get_state
  M.request({ type = "get_state" }, function(response)
    if response.success then
      state.status = "ready"
      -- Dispatch synthetic ready event
      local ready_event = { type = "rpc_ready", data = response.data }
      for _, cb in ipairs(state.wildcard_listeners) do
        cb(ready_event)
      end
      local ready_listeners = state.listeners["rpc_ready"]
      if ready_listeners then
        for _, cb in ipairs(ready_listeners) do
          cb(ready_event)
        end
      end
      if opts.on_ready then
        opts.on_ready()
      end
    else
      state.status = "dead"
      vim.notify("Pi RPC: failed readiness probe: " .. (response.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

--- Stop the RPC subprocess.
function M.stop()
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
  end
  state.job_id = nil
  state.status = "stopped"
  state.line_buffer = ""
  state.pending = {}
end

--- Restart the RPC subprocess.
---@param opts? { on_ready?: fun() }
function M.restart(opts)
  M.stop()
  M.start(opts)
end

--- Check if the RPC process is running and ready.
---@return boolean
function M.is_ready()
  return state.status == "ready"
end

--- Get the current process status.
---@return "stopped"|"starting"|"ready"|"dead"
function M.get_status()
  return state.status
end

--- Send a raw JSON command to the subprocess (fire-and-forget, no response tracking).
---@param cmd table JSON-serializable command
function M.send(cmd)
  if not state.job_id then
    return
  end
  local json_str = vim.json.encode(cmd) .. "\n"
  vim.fn.chansend(state.job_id, json_str)
end

--- Send a command and register a callback for the response.
--- Automatically assigns an id for correlation.
---@param cmd table JSON-serializable command (must have `type` field)
---@param callback fun(response: table) Called with the response
function M.request(cmd, callback)
  if not state.job_id then
    vim.schedule(function()
      callback({ type = "response", success = false, error = "RPC process not running" })
    end)
    return
  end

  local id = next_id()
  cmd.id = id
  state.pending[id] = callback

  local json_str = vim.json.encode(cmd) .. "\n"
  vim.fn.chansend(state.job_id, json_str)
end

--- Subscribe to events of a specific type.
---@param event_type string Event type to listen for (e.g. "message_update", "agent_end")
---@param callback fun(event: table) Called for each matching event
---@return fun() unsubscribe function
function M.on(event_type, callback)
  if not state.listeners[event_type] then
    state.listeners[event_type] = {}
  end
  table.insert(state.listeners[event_type], callback)

  return function()
    local listeners = state.listeners[event_type]
    if listeners then
      for i, cb in ipairs(listeners) do
        if cb == callback then
          table.remove(listeners, i)
          return
        end
      end
    end
  end
end

--- Subscribe to all events (wildcard).
---@param callback fun(event: table)
---@return fun() unsubscribe function
function M.on_any(callback)
  table.insert(state.wildcard_listeners, callback)

  return function()
    for i, cb in ipairs(state.wildcard_listeners) do
      if cb == callback then
        table.remove(state.wildcard_listeners, i)
        return
      end
    end
  end
end

--- Remove all listeners.
function M.clear_listeners()
  state.listeners = {}
  state.wildcard_listeners = {}
end

--- Ensure the RPC process is running, starting it if needed.
--- Calls callback when ready.
---@param callback fun()
function M.ensure_running(callback)
  if M.is_ready() then
    callback()
    return
  end

  M.start({ on_ready = callback })
end

--- Convenience: send a prompt to pi.
---@param message string
---@param opts? { images?: table[], streamingBehavior?: string, callback?: fun(response: table) }
function M.prompt(message, opts)
  opts = opts or {}
  local cmd = { type = "prompt", message = message }

  if opts.images then
    cmd.images = opts.images
  end
  if opts.streamingBehavior then
    cmd.streamingBehavior = opts.streamingBehavior
  end

  if opts.callback then
    M.request(cmd, opts.callback)
  else
    M.send(cmd)
  end
end

--- Convenience: abort current operation.
---@param callback? fun(response: table)
function M.abort(callback)
  if callback then
    M.request({ type = "abort" }, callback)
  else
    M.send({ type = "abort" })
  end
end

return M
