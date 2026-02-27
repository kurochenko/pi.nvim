local config = require("pi.config")

local M = {}

---@type integer|nil Terminal buffer number
M.buf = nil
---@type integer|nil Terminal window id
M.win = nil
---@type integer|nil Terminal job channel id (for chansend)
M.chan = nil

--- Snacks.nvim detection
---@type boolean, table
local has_snacks, Snacks = pcall(require, "snacks")

--- Snacks terminal instance (if using snacks)
---@type table|nil
local snacks_term = nil

--- Build the pi command with flags.
---@return string
local function build_cmd()
  local cmd = config.opts.terminal.cmd
  if config.opts.terminal.continue_session then
    cmd = cmd .. " -c"
  end
  return cmd
end

--- Get split size in columns or rows depending on position.
---@return integer
local function split_size()
  local pos = config.opts.terminal.position
  if pos == "bottom" then
    return math.floor(vim.o.lines * config.opts.terminal.size)
  else
    return math.floor(vim.o.columns * config.opts.terminal.size)
  end
end

--- Reset internal state (called when terminal buffer is deleted or process exits).
local function reset_state()
  M.buf = nil
  M.win = nil
  M.chan = nil
  snacks_term = nil
end

--- Set up autocmds to track terminal lifecycle.
---@param buf integer
local function setup_autocmds(buf)
  local group = vim.api.nvim_create_augroup("PiTerminal", { clear = true })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = reset_state,
    desc = "pi.nvim: reset terminal state on buffer delete",
  })

  vim.api.nvim_create_autocmd("TermClose", {
    group = group,
    buffer = buf,
    callback = function()
      -- Defer so the buffer can be cleaned up
      vim.schedule(reset_state)
    end,
    desc = "pi.nvim: reset terminal state on process exit",
  })
end

--- Open the terminal panel using snacks.terminal.
---@param cmd string
---@param enter boolean
local function open_snacks(cmd, enter)
  local pos = config.opts.terminal.position
  local snacks_opts = {
    win = {
      position = pos,
      enter = enter,
      wo = { winbar = "" },
    },
    bo = { filetype = "pi_terminal" },
  }

  if pos == "bottom" then
    snacks_opts.win.height = split_size()
  else
    snacks_opts.win.width = split_size()
  end

  local ok, result = pcall(Snacks.terminal.open, cmd, snacks_opts)
  if not ok then
    vim.notify("Pi: failed to open terminal via snacks.nvim: " .. tostring(result), vim.log.levels.ERROR)
    return
  end

  snacks_term = result

  if snacks_term and snacks_term.buf then
    M.buf = snacks_term.buf
    M.win = snacks_term.win
    -- Find the terminal channel from the buffer
    M.chan = vim.bo[M.buf].channel
    setup_autocmds(M.buf)
  else
    vim.notify("Pi: snacks.terminal.open returned unexpected result", vim.log.levels.ERROR)
    snacks_term = nil
  end
end

--- Open the terminal panel using manual split + termopen.
---@param cmd string
---@param enter boolean
local function open_manual(cmd, enter)
  local pos = config.opts.terminal.position
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
  M.chan = vim.fn.termopen(cmd)
  M.buf = vim.api.nvim_get_current_buf()

  vim.bo[M.buf].filetype = "pi_terminal"
  vim.wo[M.win].winbar = ""

  setup_autocmds(M.buf)

  if not enter then
    vim.api.nvim_set_current_win(source_win)
  end
end

--- Re-open the existing terminal buffer in a new split.
---@param enter boolean
---@return boolean success
local function reopen_split(enter)
  -- Guard: ensure buffer is still valid before attempting to reopen
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    reset_state()
    return false
  end

  local pos = config.opts.terminal.position
  local size = split_size()
  local source_win = vim.api.nvim_get_current_win()

  if pos == "bottom" then
    vim.cmd("botright " .. size .. "split")
  elseif pos == "left" then
    vim.cmd("topleft " .. size .. "vsplit")
  else
    vim.cmd("botright " .. size .. "vsplit")
  end

  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.wo[M.win].winbar = ""

  if not enter then
    vim.api.nvim_set_current_win(source_win)
  end

  return true
end

--- Check if the terminal window is currently visible.
---@return boolean
function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Check if the terminal buffer and process are alive.
---@return boolean
function M.is_alive()
  return M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf) and M.chan ~= nil
end

--- Open the pi terminal panel.
---@param opts? { enter?: boolean }
function M.open(opts)
  opts = opts or {}
  local enter = opts.enter ~= nil and opts.enter or false

  -- Already open and visible — just focus if requested
  if M.is_open() then
    if enter then
      vim.api.nvim_set_current_win(M.win)
    end
    return
  end

  -- Buffer exists but window was closed — reopen in a split
  if M.is_alive() then
    if reopen_split(enter) then
      return
    end
    -- Buffer became invalid between is_alive() check and reopen — fall through to fresh start
  end

  -- Fresh start: launch pi in a new terminal
  local cmd = build_cmd()

  if has_snacks then
    open_snacks(cmd, enter)
  else
    open_manual(cmd, enter)
  end
end

--- Close the terminal window (keeps buffer/process alive).
function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(M.win, false)
    M.win = nil
  end
end

--- Toggle the terminal panel.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Focus the terminal window.
function M.focus()
  if M.is_open() then
    vim.api.nvim_set_current_win(M.win)
  end
end

--- Perform the actual paste into the terminal.
---@param text string
---@param submit boolean Whether to press Enter after pasting
local function do_send(text, submit)
  if M.chan == nil then
    return
  end

  -- Optionally clear pi's editor with Ctrl-C before pasting
  if config.opts.terminal.clear_before_send then
    vim.fn.chansend(M.chan, "\x03")
  end

  -- After a brief delay, paste the prompt
  vim.defer_fn(function()
    if M.chan == nil then
      return
    end
    -- Bracketed paste: \x1b[200~ ... \x1b[201~
    vim.fn.chansend(M.chan, "\x1b[200~" .. text .. "\x1b[201~")
    -- Only submit with Enter if requested
    if submit then
      vim.fn.chansend(M.chan, "\r")
    end
  end, config.opts.terminal.send_delay)
end

--- Poll for terminal readiness, then send. Gives up after max_retries.
---@param text string
---@param submit boolean
---@param attempt integer
local function wait_and_send(text, submit, attempt)
  local max_retries = config.opts.terminal.max_retries
  local delay = math.floor(config.opts.terminal.startup_timeout / max_retries)

  if attempt >= max_retries then
    vim.notify(
      string.format("Pi: terminal failed to start after %dms (%d retries)", config.opts.terminal.startup_timeout, max_retries),
      vim.log.levels.ERROR
    )
    return
  end

  vim.defer_fn(function()
    if M.is_alive() then
      if not M.is_open() then
        M.open()
      end
      do_send(text, submit)
    else
      wait_and_send(text, submit, attempt + 1)
    end
  end, delay)
end

--- Send a prompt to pi via bracketed paste.
--- If the terminal isn't running, starts it and polls until ready (with timeout).
---@param text string
---@param opts? { submit?: boolean } Whether to press Enter after pasting (default true)
function M.send(text, opts)
  opts = opts or {}
  local submit = opts.submit ~= false -- default true

  if not M.is_alive() then
    M.open()
    wait_and_send(text, submit, 0)
    return
  end

  -- Make sure the panel is visible
  if not M.is_open() then
    M.open()
  end

  do_send(text, submit)
end

--- Send abort signal to pi (Escape key).
--- Sends Escape twice with a short delay to avoid ambiguity with escape sequences.
function M.send_abort()
  if M.chan == nil then
    return
  end
  vim.fn.chansend(M.chan, "\x1b")
  vim.defer_fn(function()
    if M.chan ~= nil then
      vim.fn.chansend(M.chan, "\x1b")
    end
  end, 10)
end

return M
