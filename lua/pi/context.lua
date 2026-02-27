local config = require("pi.config")

local M = {}

local ns = vim.api.nvim_create_namespace("PiContext")

---@class pi.Context.Range
---@field from integer[] { line, col } 1-indexed
---@field to integer[] { line, col } 1-indexed
---@field kind? "char"|"line"|"block"

---@class pi.Context
---@field win integer Source window
---@field buf integer Source buffer
---@field cursor integer[] Cursor position { row, col }
---@field range? pi.Context.Range Visual selection or operator range
local Context = {}
Context.__index = Context

--- Check if a buffer is a regular file buffer (not terminal, scratch, etc.)
---@param buf integer
---@return boolean
local function is_buf_valid(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local bt = vim.bo[buf].buftype
  if bt ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= ""
end

--- Find the last-used window with a regular file buffer.
--- Skips terminal, floating, and special windows.
---@return integer|nil win, integer|nil buf
local function find_source_window()
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)

  -- Try current window first
  if is_buf_valid(cur_buf) then
    local win_config = vim.api.nvim_win_get_config(cur_win)
    if win_config.relative == "" then -- not a floating window
      return cur_win, cur_buf
    end
  end

  -- Fall back to previous window
  local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev_win ~= 0 and vim.api.nvim_win_is_valid(prev_win) then
    local prev_buf = vim.api.nvim_win_get_buf(prev_win)
    if is_buf_valid(prev_buf) then
      return prev_win, prev_buf
    end
  end

  -- Search all windows in current tab
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local win_config = vim.api.nvim_win_get_config(win)
    if is_buf_valid(buf) and win_config.relative == "" then
      return win, buf
    end
  end

  return nil, nil
end

--- Get relative file path for a buffer.
---@param buf integer
---@return string
local function buf_path(buf)
  local full = vim.api.nvim_buf_get_name(buf)
  local cwd = vim.fn.getcwd()
  if full:sub(1, #cwd + 1) == cwd .. "/" then
    return full:sub(#cwd + 2)
  end
  return vim.fn.fnamemodify(full, ":~")
end

--- Get filetype for code fence language hint.
---@param buf integer
---@return string
local function buf_filetype(buf)
  local ft = vim.bo[buf].filetype
  if ft == "" then
    ft = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":e") or ""
  end
  return ft
end

--- Capture the current visual selection range.
---@return pi.Context.Range|nil
local function capture_visual_range()
  local mode = vim.fn.mode()
  -- If in visual mode, exit to update '< and '> marks
  if mode:match("[vV\22]") then
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  -- Ensure start <= end
  if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
    start_pos, end_pos = end_pos, start_pos
  end

  return {
    from = { start_pos[2], start_pos[3] },
    to = { end_pos[2], end_pos[3] },
  }
end

--- Create a new context, capturing current editor state.
---@param range? pi.Context.Range Explicit range (from operator mode)
---@return pi.Context
function Context.new(range)
  local self = setmetatable({}, Context)
  local win, buf = find_source_window()

  self.win = win or 0
  self.buf = buf or 0
  self.cursor = win and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
  self.range = range or capture_visual_range()

  -- Highlight the range if present
  if self.range and buf and vim.api.nvim_buf_is_valid(buf) then
    local r = self.range
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, r.from[1] - 1, 0, {
      end_row = r.to[1] - 1,
      end_col = 0,
      hl_group = "Visual",
      hl_eol = true,
    })
  end

  return self
end

--- Clear context highlight extmarks.
function Context:clear()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  end
end

--- Clear highlights and restore visual selection.
function Context:resume()
  self:clear()
  if self.range then
    pcall(function()
      vim.api.nvim_set_current_win(self.win)
      vim.cmd("normal! gv")
    end)
  end
end

--- Get a compact file reference (path + line range) for the context.
--- Returns a single-line string like "lua/pi/init.lua:12-25 " suitable
--- for typing into pi's editor without bracketed paste.
---@return string|nil
function Context:ref()
  if not is_buf_valid(self.buf) then
    return nil
  end

  local path = buf_path(self.buf)

  if self.range then
    local total_lines = vim.api.nvim_buf_line_count(self.buf)
    local start_line = math.max(self.range.from[1], 1)
    local end_line = math.min(self.range.to[1], total_lines)
    if start_line == end_line then
      return string.format("%s:%d ", path, start_line)
    else
      return string.format("%s:%d-%d ", path, start_line, end_line)
    end
  else
    return string.format("%s:%d ", path, self.cursor[1])
  end
end

-- ==========================================================================
-- Context providers
-- ==========================================================================

--- @this: Selected code or code around cursor.
---@return string|nil
function Context:this()
  if not is_buf_valid(self.buf) then
    return nil
  end

  local path = buf_path(self.buf)
  local ft = buf_filetype(self.buf)
  local total_lines = vim.api.nvim_buf_line_count(self.buf)

  if self.range then
    local start_line = math.max(self.range.from[1], 1)
    local end_line = math.min(self.range.to[1], total_lines)
    local lines = vim.api.nvim_buf_get_lines(self.buf, start_line - 1, end_line, false)
    local code = table.concat(lines, "\n")
    return string.format("File: `%s` (lines %d-%d)\n```%s\n%s\n```", path, start_line, end_line, ft, code)
  else
    -- No selection: cursor line ± 5 lines of context
    local row = self.cursor[1]
    local start_line = math.max(row - 5, 1)
    local end_line = math.min(row + 5, total_lines)
    local lines = vim.api.nvim_buf_get_lines(self.buf, start_line - 1, end_line, false)
    local code = table.concat(lines, "\n")
    return string.format("File: `%s` (around line %d)\n```%s\n%s\n```", path, row, ft, code)
  end
end

--- @buffer: Full buffer content.
---@return string|nil
function Context:buffer()
  if not is_buf_valid(self.buf) then
    return nil
  end

  local path = buf_path(self.buf)
  local ft = buf_filetype(self.buf)
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local total = #lines

  if total > 500 then
    local top = {}
    for i = 1, 250 do
      top[i] = lines[i]
    end
    local bottom = {}
    for i = total - 249, total do
      bottom[#bottom + 1] = lines[i]
    end
    local code = table.concat(top, "\n")
      .. "\n\n... ("
      .. (total - 500)
      .. " lines truncated) ...\n\n"
      .. table.concat(bottom, "\n")
    return string.format("File: `%s` (%d lines, truncated)\n```%s\n%s\n```", path, total, ft, code)
  end

  local code = table.concat(lines, "\n")
  return string.format("File: `%s`\n```%s\n%s\n```", path, ft, code)
end

--- @buffers: List of all loaded file buffers with previews.
---@return string|nil
function Context:buffers()
  local entries = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and is_buf_valid(buf) then
      local path = buf_path(buf)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, 3, false)
      local preview = table.concat(lines, "\n")
      local ft = buf_filetype(buf)
      entries[#entries + 1] = string.format("- `%s`\n  ```%s\n  %s\n  ```", path, ft, preview)
    end
  end

  if #entries == 0 then
    return nil
  end

  return "Loaded buffers:\n" .. table.concat(entries, "\n")
end

--- @visible: Content visible in all windows.
---@return string|nil
function Context:visible_text()
  local entries = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local win_config = vim.api.nvim_win_get_config(win)
    if is_buf_valid(buf) and win_config.relative == "" then
      local path = buf_path(buf)
      local ft = buf_filetype(buf)
      local top = vim.fn.line("w0", win)
      local bot = vim.fn.line("w$", win)
      local lines = vim.api.nvim_buf_get_lines(buf, top - 1, bot, false)
      local code = table.concat(lines, "\n")
      entries[#entries + 1] = string.format("File: `%s` (lines %d-%d)\n```%s\n%s\n```", path, top, bot, ft, code)
    end
  end

  if #entries == 0 then
    return nil
  end

  return table.concat(entries, "\n\n")
end

--- @diagnostics: LSP diagnostics for the current buffer.
---@return string|nil
function Context:diagnostics()
  if not is_buf_valid(self.buf) then
    return nil
  end

  local diags = vim.diagnostic.get(self.buf)
  if #diags == 0 then
    return nil
  end

  local path = buf_path(self.buf)
  local severity_names = { "Error", "Warning", "Info", "Hint" }
  local entries = {}
  for _, d in ipairs(diags) do
    local sev = severity_names[d.severity] or "Unknown"
    local source = d.source or ""
    if source ~= "" then
      source = " [" .. source .. "]"
    end
    entries[#entries + 1] = string.format("- %s (line %d): %s%s", sev, d.lnum + 1, d.message, source)
  end

  return string.format("%d diagnostics in `%s`:\n%s", #diags, path, table.concat(entries, "\n"))
end

--- @quickfix: Quickfix list entries.
---@return string|nil
function Context:quickfix()
  local qflist = vim.fn.getqflist()
  if #qflist == 0 then
    return nil
  end

  local entries = {}
  for _, item in ipairs(qflist) do
    local fname = ""
    if item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
      fname = buf_path(item.bufnr)
    end
    entries[#entries + 1] = string.format("- `%s`:%d:%d %s", fname, item.lnum, item.col, item.text)
  end

  return "Quickfix list:\n" .. table.concat(entries, "\n")
end

--- @diff: Git diff output.
---@return string|nil
function Context:diff()
  local output = vim.fn.system("git --no-pager diff")
  if vim.v.shell_error ~= 0 or output == nil or vim.trim(output) == "" then
    return nil
  end
  return "```diff\n" .. vim.trim(output) .. "\n```"
end

-- ==========================================================================
-- Provider registry and prompt resolution
-- ==========================================================================

---@type table<string, fun(ctx: pi.Context): string|nil>
local providers = {
  ["@this"] = Context.this,
  ["@buffer"] = Context.buffer,
  ["@buffers"] = Context.buffers,
  ["@visible"] = Context.visible_text,
  ["@diagnostics"] = Context.diagnostics,
  ["@quickfix"] = Context.quickfix,
  ["@diff"] = Context.diff,
}

--- Resolve @placeholders in prompt text using context providers.
--- Only resolves placeholders enabled in config.contexts.
---@param prompt_text string
---@param ctx pi.Context
---@return string
function M.resolve(prompt_text, ctx)
  -- Sort placeholders longest-first to avoid partial matches (@buffers before @buffer)
  local placeholders = {}
  for placeholder, enabled in pairs(config.opts.contexts) do
    if enabled and providers[placeholder] then
      placeholders[#placeholders + 1] = placeholder
    end
  end
  table.sort(placeholders, function(a, b)
    return #a > #b
  end)

  for _, placeholder in ipairs(placeholders) do
    if prompt_text:find(placeholder, 1, true) then
      local result = providers[placeholder](ctx)
      if result then
        prompt_text = prompt_text:gsub(vim.pesc(placeholder), function()
          return result
        end)
      end
    end
  end

  return prompt_text
end

M.Context = Context
M.is_buf_valid = is_buf_valid

return M
