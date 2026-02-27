--- Extension UI request handler for pi RPC.
--- Handles dialog requests (select, confirm, input, editor) and
--- fire-and-forget methods (notify, setStatus, setWidget, setTitle).
local M = {}

--- Event unsubscribe functions
---@type fun()[]
local unsubs = {}

--- Active timeout timers
---@type table<string, any>
local active_timers = {}

--- Send an extension UI response back to pi.
---@param response table
local function send_response(response)
  local rpc = require("pi.rpc")
  rpc.send(response)
end

--- Cancel a timeout timer if active.
---@param id string
local function cancel_timer(id)
  if active_timers[id] then
    pcall(vim.fn.timer_stop, active_timers[id])
    active_timers[id] = nil
  end
end

--- Set up a timeout timer that auto-cancels a dialog.
---@param id string Request ID
---@param timeout_ms integer
---@param cancel_fn fun() Function to call on timeout
local function setup_timeout(id, timeout_ms, cancel_fn)
  if timeout_ms and timeout_ms > 0 then
    active_timers[id] = vim.fn.timer_start(timeout_ms, function()
      active_timers[id] = nil
      vim.schedule(function()
        cancel_fn()
      end)
    end)
  end
end

-- =========================================================================
-- Dialog handlers (require response)
-- =========================================================================

--- Handle a select request.
---@param request table
local function handle_select(request)
  local id = request.id
  local options = request.options or {}
  local title = request.title or "Select"

  -- Set up timeout
  if request.timeout then
    setup_timeout(id, request.timeout, function()
      send_response({ type = "extension_ui_response", id = id, cancelled = true })
    end)
  end

  vim.ui.select(options, { prompt = title }, function(choice)
    cancel_timer(id)
    if choice == nil then
      send_response({ type = "extension_ui_response", id = id, cancelled = true })
    else
      send_response({ type = "extension_ui_response", id = id, value = choice })
    end
  end)
end

--- Handle a confirm request.
---@param request table
local function handle_confirm(request)
  local id = request.id
  local title = request.title or "Confirm"
  local message = request.message or ""

  if request.timeout then
    setup_timeout(id, request.timeout, function()
      send_response({ type = "extension_ui_response", id = id, confirmed = false })
    end)
  end

  local prompt = title
  if message ~= "" then
    prompt = prompt .. "\n" .. message
  end

  vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
    cancel_timer(id)
    if choice == "Yes" then
      send_response({ type = "extension_ui_response", id = id, confirmed = true })
    else
      send_response({ type = "extension_ui_response", id = id, confirmed = false })
    end
  end)
end

--- Handle an input request.
---@param request table
local function handle_input(request)
  local id = request.id
  local title = request.title or "Input"
  local placeholder = request.placeholder or ""

  if request.timeout then
    setup_timeout(id, request.timeout, function()
      send_response({ type = "extension_ui_response", id = id, cancelled = true })
    end)
  end

  local has_snacks, Snacks = pcall(require, "snacks")
  if has_snacks and Snacks.input then
    Snacks.input({
      prompt = title .. ": ",
      default = placeholder,
    }, function(value)
      cancel_timer(id)
      if value == nil then
        send_response({ type = "extension_ui_response", id = id, cancelled = true })
      else
        send_response({ type = "extension_ui_response", id = id, value = value })
      end
    end)
  else
    vim.ui.input({ prompt = title .. ": ", default = placeholder }, function(value)
      cancel_timer(id)
      if value == nil then
        send_response({ type = "extension_ui_response", id = id, cancelled = true })
      else
        send_response({ type = "extension_ui_response", id = id, value = value })
      end
    end)
  end
end

--- Handle an editor request (multi-line editing).
---@param request table
local function handle_editor(request)
  local id = request.id
  local title = request.title or "Edit"
  local prefill = request.prefill or ""

  if request.timeout then
    setup_timeout(id, request.timeout, function()
      send_response({ type = "extension_ui_response", id = id, cancelled = true })
    end)
  end

  -- Create a temporary buffer for editing
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  -- Set prefill content
  local lines = vim.split(prefill, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Open in a float
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.min(math.max(#lines + 2, 10), math.floor(vim.o.lines * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  -- Submit on :w or <CR> in normal mode
  local submitted = false

  local function submit()
    if submitted then
      return
    end
    submitted = true
    cancel_timer(id)
    local result_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local value = table.concat(result_lines, "\n")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    send_response({ type = "extension_ui_response", id = id, value = value })
  end

  local function cancel()
    if submitted then
      return
    end
    submitted = true
    cancel_timer(id)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    send_response({ type = "extension_ui_response", id = id, cancelled = true })
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = submit,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    callback = cancel,
    once = true,
  })
end

-- =========================================================================
-- Fire-and-forget handlers
-- =========================================================================

--- Handle a notify request.
---@param request table
local function handle_notify(request)
  local level_map = {
    info = vim.log.levels.INFO,
    warning = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
  }
  local level = level_map[request.notifyType or "info"] or vim.log.levels.INFO
  vim.notify(request.message or "", level)
end

--- Handle setStatus (update statusline component).
---@param request table
local function handle_set_status(request)
  -- Store in events state for statusline access
  local events = require("pi.events")
  local state = events.get_state_ref()
  if not state._extension_status then
    state._extension_status = {}
  end
  if request.statusText then
    state._extension_status[request.statusKey or "default"] = request.statusText
  else
    state._extension_status[request.statusKey or "default"] = nil
  end
end

--- Handle setWidget (display text block — show as notification for now).
---@param request table
local function handle_set_widget(request)
  if request.widgetLines then
    -- Display widget lines as a notification
    vim.notify(table.concat(request.widgetLines, "\n"), vim.log.levels.INFO)
  end
end

-- =========================================================================
-- Main dispatcher
-- =========================================================================

---@type table<string, fun(request: table)>
local handlers = {
  select = handle_select,
  confirm = handle_confirm,
  input = handle_input,
  editor = handle_editor,
  notify = handle_notify,
  setStatus = handle_set_status,
  setWidget = handle_set_widget,
  setTitle = function(_) end, -- no-op in Neovim
  set_editor_text = function(_) end, -- no-op in RPC mode
}

--- Handle an extension UI request event.
---@param event table
local function on_extension_ui_request(event)
  local method = event.method
  if not method then
    return
  end

  local handler = handlers[method]
  if handler then
    handler(event)
  else
    vim.notify("Pi: unknown extension UI method: " .. method, vim.log.levels.DEBUG)
    -- Respond with cancelled for unknown dialog methods
    if event.id then
      send_response({ type = "extension_ui_response", id = event.id, cancelled = true })
    end
  end
end

--- Connect to the event system.
function M.connect()
  M.disconnect()
  local events = require("pi.events")
  unsubs[#unsubs + 1] = events.on("extension_ui_request", on_extension_ui_request)
end

--- Disconnect from the event system.
function M.disconnect()
  for _, unsub in ipairs(unsubs) do
    unsub()
  end
  unsubs = {}
  -- Cancel all active timers
  for id, _ in pairs(active_timers) do
    cancel_timer(id)
  end
end

return M
