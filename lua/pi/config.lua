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
---@field send_delay number Delay in ms between clear and paste (default 50)
---@field startup_timeout number Total timeout in ms waiting for terminal to start (default 5000)
---@field max_retries number Max poll attempts when waiting for terminal startup (default 10)
---@field clear_before_send boolean Send Ctrl-C before pasting to clear pi's editor (default true)

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
    send_delay = 50,
    startup_timeout = 5000,
    max_retries = 10,
    clear_before_send = true,
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
    model = "<leader>pm",
    cycle_model = "<leader>pn",
    cycle_thinking = "<leader>pk",
  },

  events = {
    reload = true,
  },
}

-- Initialize opts with defaults so the plugin works even if setup() is never called.
---@type pi.Config
M.opts = vim.deepcopy(M.defaults)

-- Track whether setup() was explicitly called.
M._setup_called = false

--- Validate merged config. Raises on invalid values.
---@param opts pi.Config
local function validate(opts)
  vim.validate({
    terminal = { opts.terminal, "table" },
    contexts = { opts.contexts, "table" },
    prompts = { opts.prompts, "table" },
    ask = { opts.ask, "table" },
    keymaps = { opts.keymaps, "table" },
    events = { opts.events, "table" },
  })

  vim.validate({
    ["terminal.position"] = {
      opts.terminal.position,
      function(v)
        return vim.tbl_contains({ "left", "right", "bottom" }, v)
      end,
      "one of: left, right, bottom",
    },
    ["terminal.size"] = {
      opts.terminal.size,
      function(v)
        return type(v) == "number" and v > 0 and v < 1
      end,
      "number between 0 and 1 (exclusive)",
    },
    ["terminal.cmd"] = { opts.terminal.cmd, "string" },
    ["terminal.continue_session"] = { opts.terminal.continue_session, "boolean" },
    ["terminal.auto_start"] = { opts.terminal.auto_start, "boolean" },
    ["terminal.send_delay"] = {
      opts.terminal.send_delay,
      function(v)
        return type(v) == "number" and v >= 0
      end,
      "non-negative number (ms)",
    },
    ["terminal.startup_timeout"] = {
      opts.terminal.startup_timeout,
      function(v)
        return type(v) == "number" and v > 0
      end,
      "positive number (ms)",
    },
    ["terminal.max_retries"] = {
      opts.terminal.max_retries,
      function(v)
        return type(v) == "number" and v >= 1 and v == math.floor(v)
      end,
      "positive integer",
    },
    ["terminal.clear_before_send"] = { opts.terminal.clear_before_send, "boolean" },
  })

  vim.validate({
    ["ask.prompt"] = { opts.ask.prompt, "string" },
    ["events.reload"] = { opts.events.reload, "boolean" },
  })
end

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

  -- Validate merged config — raises on invalid values
  validate(M.opts)

  M._setup_called = true
end

return M
