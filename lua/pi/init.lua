local M = {}

--- Set up pi.nvim with user configuration.
---@param opts? pi.Config
function M.setup(opts)
  local config = require("pi.config")
  config.setup(opts)
  M._setup_keymaps()

  if config.opts.terminal.auto_start then
    -- Defer to ensure Neovim UI is fully initialized
    vim.schedule(function()
      require("pi.terminal").open()
    end)
  end
end

--- Toggle the pi terminal panel.
function M.toggle()
  require("pi.terminal").toggle()
end

--- Open an input prompt, resolve context placeholders, and send to pi.
--- In visual mode, captures the selection as @this context.
---@param default_text? string Pre-filled text (e.g. "@this: ")
---@param opts? { submit?: boolean, context?: pi.Context }
function M.ask(default_text, opts)
  opts = opts or {}
  default_text = default_text or ""

  local context_mod = require("pi.context")
  local terminal = require("pi.terminal")
  local config = require("pi.config")

  -- Capture context before opening input (preserves visual selection)
  local ctx = opts.context or context_mod.Context.new()

  -- If submit is true, skip the input dialog
  if opts.submit then
    local resolved = context_mod.resolve(default_text, ctx)
    ctx:clear()
    terminal.send(resolved)
    return
  end

  -- Open input prompt
  local input_opts = {
    prompt = config.opts.ask.prompt,
    default = default_text,
  }

  local has_snacks, Snacks = pcall(require, "snacks")
  if has_snacks and Snacks.input then
    local snacks_opts = vim.tbl_deep_extend("force", {
      prompt = config.opts.ask.prompt,
      default = default_text,
      win = config.opts.ask.snacks or {},
    }, {})

    Snacks.input(snacks_opts, function(input)
      if input == nil then
        -- Cancelled
        ctx:resume()
        return
      end
      local resolved = context_mod.resolve(input, ctx)
      ctx:clear()
      terminal.send(resolved)
    end)
  else
    vim.ui.input(input_opts, function(input)
      if input == nil then
        ctx:resume()
        return
      end
      local resolved = context_mod.resolve(input, ctx)
      ctx:clear()
      terminal.send(resolved)
    end)
  end
end

--- Send a prompt directly to pi (no input dialog).
--- If text matches a named prompt from config, it expands it.
---@param text string
---@param opts? { context?: pi.Context, submit?: boolean }
function M.prompt(text, opts)
  opts = opts or {}

  local config = require("pi.config")
  local context_mod = require("pi.context")
  local terminal = require("pi.terminal")

  -- Check if text is a named prompt key
  local prompt_def = config.opts.prompts[text]
  if prompt_def then
    text = prompt_def.text
  end

  local ctx = opts.context or context_mod.Context.new()
  local resolved = context_mod.resolve(text, ctx)
  ctx:clear()
  -- Default: submit (press Enter). Pass submit=false to just paste without submitting.
  terminal.send(resolved, { submit = opts.submit ~= false })
end

--- Open a picker to select from available prompts and actions.
function M.select()
  local config = require("pi.config")
  local context_mod = require("pi.context")

  -- Capture context before opening picker
  local ctx = context_mod.Context.new()

  -- Build items list
  local items = {}

  -- Add prompts section
  for name, def in pairs(config.opts.prompts) do
    items[#items + 1] = {
      label = name .. ": " .. def.text,
      kind = "prompt",
      name = name,
      text = def.text,
    }
  end

  -- Sort prompts alphabetically
  table.sort(items, function(a, b)
    return a.name < b.name
  end)

  -- Add control actions
  items[#items + 1] = { label = "[control] abort: Cancel pi's current operation", kind = "control", action = "abort" }
  items[#items + 1] = { label = "[control] toggle: Toggle pi panel", kind = "control", action = "toggle" }

  -- Format items for vim.ui.select
  local labels = {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = item.label
  end

  vim.ui.select(labels, {
    prompt = "Pi Action:",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice == nil or idx == nil then
      ctx:resume()
      return
    end

    local selected = items[idx]

    if selected.kind == "prompt" then
      local resolved = context_mod.resolve(selected.text, ctx)
      ctx:clear()
      require("pi.terminal").send(resolved)
    elseif selected.kind == "control" then
      ctx:clear()
      if selected.action == "abort" then
        M.abort()
      elseif selected.action == "toggle" then
        M.toggle()
      end
    end
  end)
end

--- Abort pi's current operation.
function M.abort()
  require("pi.terminal").send_abort()
end

--- Send a compact file reference (path:lines) to pi's editor without submitting.
--- The reference is typed as raw keystrokes so the user can add instructions
--- and submit manually.
function M.send_context()
  local context_mod = require("pi.context")
  local terminal = require("pi.terminal")

  local ctx = context_mod.Context.new()
  local ref = ctx:ref()
  ctx:clear()

  if ref then
    terminal.send(ref, { submit = false })
  end
end

--- Create an operator function for dot-repeat support.
--- Usage: vim.keymap.set("n", "gp", function() return require("pi").operator("@this: ") end, { expr = true })
---@param prefix string Text to prepend to the prompt
---@param opts? { submit?: boolean }
---@return string "g@" to trigger operatorfunc
function M.operator(prefix, opts)
  opts = opts or {}

  ---@param kind "char"|"line"|"block"
  _G._pi_operatorfunc = function(kind)
    local start_pos = vim.api.nvim_buf_get_mark(0, "[")
    local end_pos = vim.api.nvim_buf_get_mark(0, "]")
    if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
      start_pos, end_pos = end_pos, start_pos
    end

    ---@type pi.Context.Range
    local range = {
      from = { start_pos[1], start_pos[2] },
      to = { end_pos[1], end_pos[2] },
      kind = kind,
    }

    local ctx = require("pi.context").Context.new(range)

    if opts.submit then
      M.ask(prefix, { submit = true, context = ctx })
    else
      M.ask(prefix, { context = ctx })
    end
  end

  vim.o.operatorfunc = "v:lua._pi_operatorfunc"
  return "g@"
end

--- Set up default keymaps from config.
function M._setup_keymaps()
  local config = require("pi.config")
  local km = config.opts.keymaps

  if km.toggle then
    vim.keymap.set({ "n", "t" }, km.toggle, function()
      M.toggle()
    end, { silent = true, desc = "Pi: Toggle panel" })
  end

  if km.ask then
    vim.keymap.set("n", km.ask, function()
      M.ask("@this: ")
    end, { silent = true, desc = "Pi: Ask about code" })
    vim.keymap.set("v", km.ask, function()
      M.ask("@this: ")
    end, { silent = true, desc = "Pi: Ask about selection" })
  end

  if km.select then
    vim.keymap.set({ "n", "v" }, km.select, function()
      M.select()
    end, { silent = true, desc = "Pi: Action picker" })
  end

  if km.prompt_this then
    vim.keymap.set("n", km.prompt_this, function()
      M.send_context()
    end, { silent = true, desc = "Pi: Send code context" })
    vim.keymap.set("v", km.prompt_this, function()
      M.send_context()
    end, { silent = true, desc = "Pi: Send selection" })
  end

  if km.abort then
    vim.keymap.set("n", km.abort, function()
      M.abort()
    end, { silent = true, desc = "Pi: Abort" })
  end
end

return M
