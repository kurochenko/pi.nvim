local M = {}

function M.check()
  vim.health.start("pi.nvim")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required", {
      "Update Neovim to 0.10 or later",
    })
  end

  -- Check pi CLI
  local config = require("pi.config")
  local cmd = config.opts.terminal.cmd
  if vim.fn.executable(cmd) == 1 then
    local version = vim.fn.system(cmd .. " --version")
    version = vim.trim(version or "")
    if vim.v.shell_error == 0 and version ~= "" then
      vim.health.ok(string.format("pi CLI found: %s", version))
    else
      vim.health.ok(string.format("pi CLI found at: %s", vim.fn.exepath(cmd)))
    end
  else
    vim.health.error(string.format("pi CLI not found in PATH (configured cmd: '%s')", cmd), {
      "Install pi from https://pi.dev",
      "Ensure '" .. cmd .. "' is in your PATH",
      "Or set a custom path: require('pi').setup({ terminal = { cmd = '/path/to/pi' } })",
    })
  end

  -- Check snacks.nvim (optional)
  local has_snacks = pcall(require, "snacks")
  if has_snacks then
    vim.health.ok("snacks.nvim available (enhanced terminal & input UI)")
  else
    vim.health.info("snacks.nvim not found (optional — using vim.ui and manual splits)")
  end

  -- Check setup() status
  if config._setup_called then
    vim.health.ok("setup() has been called")
  else
    vim.health.warn("setup() has not been called — using default configuration", {
      "Call require('pi').setup() in your Neovim config",
      "This is recommended but not required; defaults work out of the box",
    })
  end

  -- Validate terminal config
  local t = config.opts.terminal
  if t.size > 0 and t.size < 1 then
    vim.health.ok(string.format("Terminal: position=%s, size=%.0f%%", t.position, t.size * 100))
  else
    vim.health.warn(string.format("Terminal size %.2f is outside recommended range (0.0-1.0)", t.size))
  end
end

return M
