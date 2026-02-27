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
vim.api.nvim_set_hl(0, "PiUser", { default = true, link = "Title" })
vim.api.nvim_set_hl(0, "PiAssistant", { default = true, link = "Function" })
vim.api.nvim_set_hl(0, "PiThinking", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "PiTool", { default = true, link = "Type" })
vim.api.nvim_set_hl(0, "PiToolError", { default = true, link = "DiagnosticError" })
vim.api.nvim_set_hl(0, "PiMeta", { default = true, link = "NonText" })
vim.api.nvim_set_hl(0, "PiCost", { default = true, link = "Number" })
vim.api.nvim_set_hl(0, "PiStreaming", { default = true, link = "WarningMsg" })

-- File reload autocmds: detect files edited by pi
local reload_group = vim.api.nvim_create_augroup("PiFileReload", { clear = true })

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
  group = reload_group,
  callback = function()
    local ok, config = pcall(require, "pi.config")
    if not ok or not config.opts or not config.opts.events.reload then
      return
    end
    vim.schedule(function()
      pcall(vim.cmd, "checktime")
    end)
  end,
  desc = "pi.nvim: reload buffers when files change externally",
})

-- Cleanup on VimLeavePre
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("PiCleanup", { clear = true }),
  callback = function()
    -- Stop RPC process
    local rpc_ok, rpc = pcall(require, "pi.rpc")
    if rpc_ok then
      pcall(rpc.stop)
    end
    -- Close terminal if open
    local term_ok, terminal = pcall(require, "pi.terminal")
    if term_ok and terminal.is_open() then
      pcall(terminal.close)
    end
  end,
  desc = "pi.nvim: cleanup on exit",
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
  elseif subcmd == "model" then
    pi.pick_model()
  elseif subcmd == "cycle-model" then
    pi.cycle_model()
  elseif subcmd == "thinking" then
    pi.cycle_thinking()
  elseif subcmd == "session" then
    local action = args[2] or "stats"
    if action == "new" then
      pi.new_session()
    elseif action == "stats" then
      pi.session_stats()
    else
      vim.notify("Pi: unknown session action: " .. action, vim.log.levels.WARN)
    end
  elseif subcmd == "export" then
    pi.export_html()
  elseif subcmd == "restart" then
    local rpc = require("pi.rpc")
    rpc.restart({
      on_ready = function()
        vim.notify("Pi: RPC restarted")
      end,
    })
  elseif subcmd == "stats" then
    pi.session_stats()
  else
    -- Treat entire input as a prompt
    local text = table.concat(args, " ")
    pi.prompt(text)
  end
end, {
  nargs = "*",
  desc = "Pi coding agent",
  complete = function(_, line)
    local subcmds = {
      "toggle", "ask", "prompt", "select", "abort",
      "model", "cycle-model", "thinking",
      "session", "export", "restart", "stats",
    }
    local parts = vim.split(vim.trim(line), "%s+")
    if #parts <= 2 then
      local prefix = parts[2] or ""
      return vim.tbl_filter(function(s)
        return s:find(prefix, 1, true) == 1
      end, subcmds)
    end
    -- :Pi prompt <name>
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
    -- :Pi session <action>
    if parts[2] == "session" and #parts <= 3 then
      local prefix = parts[3] or ""
      local actions = { "new", "stats" }
      return vim.tbl_filter(function(s)
        return s:find(prefix, 1, true) == 1
      end, actions)
    end
    return {}
  end,
})
