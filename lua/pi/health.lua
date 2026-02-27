local M = {}

-- Compat: vim.health API was renamed in 0.10 (report_start → start, etc.)
local health = {}
if vim.fn.has("nvim-0.10") == 1 then
  health.start = vim.health.start
  health.ok = vim.health.ok
  health.warn = vim.health.warn
  health.info = vim.health.info
  health.error = vim.health.error
else
  health.start = vim.health.report_start
  health.ok = vim.health.report_ok
  health.warn = vim.health.report_warn
  health.info = vim.health.report_info
  health.error = vim.health.report_error
end

function M.check()
  health.start("pi.nvim")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim >= 0.10 required", {
      "Update Neovim to 0.10 or later",
    })
  end

  -- Check pi CLI
  local config = require("pi.config")
  local cmd = config.opts.rpc.cmd or config.opts.terminal.cmd
  if vim.fn.executable(cmd) == 1 then
    local version = vim.fn.system(cmd .. " --version")
    version = vim.trim(version or "")
    if vim.v.shell_error == 0 and version ~= "" then
      health.ok(string.format("pi CLI found: %s", version))
    else
      health.ok(string.format("pi CLI found at: %s", vim.fn.exepath(cmd)))
    end
  else
    health.error(string.format("pi CLI not found in PATH (configured cmd: '%s')", cmd), {
      "Install pi from https://pi.dev",
      "Ensure '" .. cmd .. "' is in your PATH",
      "Or set a custom path: require('pi').setup({ rpc = { cmd = '/path/to/pi' } })",
    })
  end

  -- Check snacks.nvim (optional)
  local has_snacks = pcall(require, "snacks")
  if has_snacks then
    health.ok("snacks.nvim available (enhanced input UI)")
  else
    health.info("snacks.nvim not found (optional — using vim.ui)")
  end

  -- Check setup() status
  if config._setup_called then
    health.ok("setup() has been called")
  else
    health.warn("setup() has not been called — using default configuration", {
      "Call require('pi').setup() in your Neovim config",
      "This is recommended but not required; defaults work out of the box",
    })
  end

  -- Report current mode
  local mode = config.opts.mode or "rpc"
  health.info(string.format("Mode: %s", mode))

  if mode == "rpc" then
    -- Check RPC process status
    local rpc_ok, rpc = pcall(require, "pi.rpc")
    if rpc_ok then
      local status = rpc.get_status()
      if status == "ready" then
        health.ok("RPC process: running and ready")
        -- Get state for details
        local events = require("pi.events")
        local state = events.get_state_ref()
        if state.model then
          health.info(string.format("Model: %s (%s)", state.model.name or "?", state.model.provider or "?"))
        end
        if state.thinking_level then
          health.info(string.format("Thinking: %s", state.thinking_level))
        end
        health.info(string.format("Messages: %d", state.message_count))
      elseif status == "starting" then
        health.warn("RPC process: starting...")
      elseif status == "dead" then
        health.error("RPC process: dead (exited unexpectedly)", {
          "Try :Pi restart or restart Neovim",
        })
      else
        health.info("RPC process: not started")
      end
    end

    -- RPC config
    local rpc_cfg = config.opts.rpc
    health.info(string.format("RPC: position=%s, size=%.0f%%", rpc_cfg.position, rpc_cfg.size * 100))
  else
    -- Terminal config
    local t = config.opts.terminal
    if t.size > 0 and t.size < 1 then
      health.ok(string.format("Terminal: position=%s, size=%.0f%%", t.position, t.size * 100))
    else
      health.warn(string.format("Terminal size %.2f is outside recommended range (0.0-1.0)", t.size))
    end
  end
end

return M
