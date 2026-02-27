---@class pi.Config
---@field terminal pi.Config.Terminal
---@field contexts table<string, boolean>
---@field prompts table<string, pi.Config.Prompt>
---@field ask pi.Config.Ask
---@field keymaps table<string, string|false>
---@field events pi.Config.Events

---@class pi.Config.Terminal
---@field position "left"|"right"|"bottom"
---@field size number Fraction of screen (0.0-1.0)
---@field cmd string Pi executable command
---@field continue_session boolean Pass -c flag to continue previous session
---@field auto_start boolean Open terminal panel on setup

---@class pi.Config.Prompt
---@field text string Prompt text (may contain @placeholders)
---@field submit boolean Send immediately without input dialog

---@class pi.Config.Ask
---@field prompt string Input prompt prefix
---@field snacks? table Snacks.input window options

---@class pi.Config.Events
---@field reload boolean Auto-reload buffers when files change

local M = {}

---@type pi.Config
M.defaults = {
  terminal = {
    position = "right",
    size = 0.4,
    cmd = "pi",
    continue_session = true,
    auto_start = false,
  },

  contexts = {
    ["@this"] = true,
    ["@buffer"] = true,
    ["@buffers"] = true,
    ["@visible"] = true,
    ["@diagnostics"] = true,
    ["@quickfix"] = true,
    ["@diff"] = true,
  },

  prompts = {
    explain = { text = "Explain @this and its context", submit = true },
    review = { text = "Review @this for correctness and readability", submit = true },
    fix = { text = "Fix @diagnostics", submit = true },
    test = { text = "Add tests for @this", submit = true },
    document = { text = "Add documentation comments to @this", submit = true },
    optimize = { text = "Optimize @this for performance and readability", submit = true },
    implement = { text = "Implement @this", submit = true },
    diff = { text = "Review the following git diff for correctness and readability: @diff", submit = true },
  },

  ask = {
    prompt = "pi> ",
    snacks = {},
  },

  keymaps = {
    toggle = "<leader>pt",
    ask = "<leader>pa",
    select = "<leader>px",
    prompt_this = "<leader>pp",
    abort = "<leader>pq",
  },

  events = {
    reload = true,
  },
}

---@type pi.Config|nil
M.opts = nil

--- Merge user options with defaults.
--- Setting a prompt or context key to false removes it.
---@param user_opts? pi.Config
function M.setup(user_opts)
  M.opts = vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})

  -- Allow disabling individual prompts by setting them to false
  if user_opts and user_opts.prompts then
    for key, val in pairs(user_opts.prompts) do
      if val == false then
        M.opts.prompts[key] = nil
      end
    end
  end

  -- Allow disabling individual contexts by setting them to false
  if user_opts and user_opts.contexts then
    for key, val in pairs(user_opts.contexts) do
      if val == false then
        M.opts.contexts[key] = nil
      end
    end
  end

  -- Allow disabling individual keymaps by setting them to false
  if user_opts and user_opts.keymaps then
    for key, val in pairs(user_opts.keymaps) do
      if val == false then
        M.opts.keymaps[key] = nil
      end
    end
  end
end

return M
