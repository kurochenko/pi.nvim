-- pi.nvim plugin auto-load
-- Runs automatically when lazy.nvim loads the plugin

if vim.g.loaded_pi then
  return
end
vim.g.loaded_pi = 1

-- Highlight groups
vim.api.nvim_set_hl(0, "PiContextPlaceholder", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "PiContextValue", { default = true, link = "String" })
vim.api.nvim_set_hl(0, "PiTerminalBorder", { default = true, link = "FloatBorder" })

-- File reload autocmds: detect files edited by pi
local reload_group = vim.api.nvim_create_augroup("PiFileReload", { clear = true })

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
  group = reload_group,
  callback = function()
    -- Check if pi.nvim is configured and reload is enabled
    local ok, config = pcall(require, "pi.config")
    if not ok or not config.opts or not config.opts.events.reload then
      return
    end
    -- Schedule to avoid blocking event loop
    vim.schedule(function()
      pcall(vim.cmd, "checktime")
    end)
  end,
  desc = "pi.nvim: reload buffers when files change externally",
})

-- Terminal cleanup on VimLeavePre
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("PiCleanup", { clear = true }),
  callback = function()
    local ok, terminal = pcall(require, "pi.terminal")
    if ok and terminal.is_open() then
      pcall(terminal.close)
    end
  end,
  desc = "pi.nvim: close terminal panel on exit",
})

-- User commands
vim.api.nvim_create_user_command("Pi", function(cmd_opts)
  local args = cmd_opts.fargs
  local subcmd = args[1] or "toggle"
  local pi = require("pi")

  if subcmd == "toggle" then
    pi.toggle()
  elseif subcmd == "ask" then
    local text = table.concat(vim.list_slice(args, 2), " ")
    pi.ask(text ~= "" and text or nil)
  elseif subcmd == "prompt" then
    local text = table.concat(vim.list_slice(args, 2), " ")
    if text ~= "" then
      pi.prompt(text)
    else
      vim.notify("Pi: prompt requires text argument", vim.log.levels.WARN)
    end
  elseif subcmd == "select" then
    pi.select()
  elseif subcmd == "abort" then
    pi.abort()
  else
    -- Treat entire input as a prompt
    local text = table.concat(args, " ")
    pi.prompt(text)
  end
end, {
  nargs = "*",
  desc = "Pi coding agent",
  complete = function(_, line)
    local subcmds = { "toggle", "ask", "prompt", "select", "abort" }
    local parts = vim.split(vim.trim(line), "%s+")
    if #parts <= 2 then
      local prefix = parts[2] or ""
      return vim.tbl_filter(function(s)
        return s:find(prefix, 1, true) == 1
      end, subcmds)
    end
    -- For :Pi prompt <name>, complete with named prompts
    if parts[2] == "prompt" and #parts <= 3 then
      local ok, config = pcall(require, "pi.config")
      if ok and config.opts then
        local prefix = parts[3] or ""
        local names = vim.tbl_keys(config.opts.prompts)
        return vim.tbl_filter(function(s)
          return s:find(prefix, 1, true) == 1
        end, names)
      end
    end
    return {}
  end,
})
