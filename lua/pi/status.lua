--- Statusline integration for pi.nvim.
--- Provides functions that return strings for use in lualine or custom statuslines.
local M = {}

--- Get the current model name (short form).
---@return string
function M.model()
  local events = require("pi.events")
  local state = events.get_state_ref()
  if state.model then
    return state.model.name or state.model.id or ""
  end
  return ""
end

--- Get the current thinking level.
---@return string
function M.thinking()
  local events = require("pi.events")
  local state = events.get_state_ref()
  return state.thinking_level or ""
end

--- Get the current agent state.
---@return string "streaming"|"compacting"|"retrying"|"idle"|"disconnected"
function M.state()
  local events = require("pi.events")
  local state = events.get_state_ref()

  if state.rpc_status == "dead" or state.rpc_status == "stopped" then
    return "disconnected"
  end
  if state.is_streaming then
    return "streaming"
  end
  if state.is_compacting then
    return "compacting"
  end
  if state.is_retrying then
    return "retrying"
  end
  return "idle"
end

--- Get formatted cost string.
---@return string
function M.cost()
  -- Cost requires a get_session_stats call; return cached if available
  local events = require("pi.events")
  local state = events.get_state_ref()
  if state._session_cost then
    return string.format("$%.4f", state._session_cost)
  end
  return ""
end

--- Get a complete statusline string.
--- Format: "Pi: model [thinking] ● state"
---@return string
function M.statusline()
  local events = require("pi.events")
  local state = events.get_state_ref()

  if state.rpc_status == "dead" or state.rpc_status == "stopped" then
    return "Pi: disconnected"
  end

  local parts = { "Pi:" }

  -- Model name
  if state.model then
    parts[#parts + 1] = state.model.name or state.model.id or "?"
  end

  -- Thinking level
  if state.thinking_level and state.thinking_level ~= "" and state.thinking_level ~= "off" then
    parts[#parts + 1] = "[" .. state.thinking_level .. "]"
  end

  -- State indicator
  local indicator
  if state.is_streaming then
    indicator = "● streaming"
  elseif state.is_compacting then
    indicator = "◐ compacting"
  elseif state.is_retrying then
    indicator = "↻ retrying"
  else
    indicator = "○ idle"
  end
  parts[#parts + 1] = indicator

  return table.concat(parts, " ")
end

--- Check if the pi RPC is connected (useful for conditional statusline display).
---@return boolean
function M.is_connected()
  local events = require("pi.events")
  local state = events.get_state_ref()
  return state.rpc_status == "ready"
end

--- Lualine component table (for direct use as lualine component).
--- Usage: require('lualine').setup({ sections = { lualine_x = { require('pi.status').lualine } } })
M.lualine = {
  function()
    return M.statusline()
  end,
  cond = function()
    return M.is_connected()
  end,
}

return M
