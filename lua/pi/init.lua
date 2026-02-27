local M = {}

--- Set up pi.nvim with user configuration.
---@param opts? pi.Config
function M.setup(opts)
  local config = require("pi.config")
  config.setup(opts)
  M._setup_keymaps()

  local mode = config.opts.mode or "rpc"

  if mode == "rpc" then
    -- Connect event system and streaming handler
    local events = require("pi.events")
    local stream = require("pi.stream")
    events.connect()
    stream.connect()

    if config.opts.rpc and config.opts.rpc.auto_start ~= false then
      vim.schedule(function()
        local rpc = require("pi.rpc")
        rpc.start({
          on_ready = function()
            -- Load existing conversation into chat buffer
            M._load_history()
          end,
        })
      end)
    end
  elseif mode == "terminal" then
    if config.opts.terminal.auto_start then
      vim.schedule(function()
        require("pi.terminal").open()
      end)
    end
  end
end

--- Load conversation history from an existing session into the chat buffer.
function M._load_history()
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    return
  end

  rpc.request({ type = "get_messages" }, function(response)
    if response.success and response.data and response.data.messages then
      local messages = response.data.messages
      if #messages > 0 then
        local chat = require("pi.chat")
        chat.open()
        chat.render_messages(messages)
      end
    end
  end)
end

--- Toggle the pi panel.
function M.toggle()
  local config = require("pi.config")
  if (config.opts.mode or "rpc") == "terminal" then
    require("pi.terminal").toggle()
  else
    local chat = require("pi.chat")
    chat.toggle()
  end
end

--- Open an input prompt, resolve context placeholders, and send to pi.
--- In visual mode, captures the selection as @this context.
---@param default_text? string Pre-filled text (e.g. "@this: ")
---@param opts? { submit?: boolean, context?: pi.Context }
function M.ask(default_text, opts)
  opts = opts or {}
  default_text = default_text or ""

  local context_mod = require("pi.context")
  local config = require("pi.config")

  -- Capture context before opening input (preserves visual selection)
  local ctx = opts.context or context_mod.Context.new()

  -- If submit is true, skip the input dialog
  if opts.submit then
    local resolved = context_mod.resolve(default_text, ctx)
    ctx:clear()
    M._send_resolved(resolved)
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
        ctx:resume()
        return
      end
      local resolved = context_mod.resolve(input, ctx)
      ctx:clear()
      M._send_resolved(resolved)
    end)
  else
    vim.ui.input(input_opts, function(input)
      if input == nil then
        ctx:resume()
        return
      end
      local resolved = context_mod.resolve(input, ctx)
      ctx:clear()
      M._send_resolved(resolved)
    end)
  end
end

--- Send resolved text to pi (routes to RPC or terminal based on mode).
---@param text string
---@param opts? { submit?: boolean }
function M._send_resolved(text, opts)
  opts = opts or {}
  local config = require("pi.config")
  local mode = config.opts.mode or "rpc"

  if mode == "terminal" then
    require("pi.terminal").send(text, { submit = opts.submit ~= false })
    return
  end

  -- RPC mode
  local rpc = require("pi.rpc")
  local chat = require("pi.chat")
  local events = require("pi.events")

  -- Ensure chat is visible
  chat.open()

  local state = events.get_state_ref()

  rpc.ensure_running(function()
    local cmd = { type = "prompt", message = text }

    -- Handle streaming behavior
    if state.is_streaming then
      cmd.streamingBehavior = "followUp"
    end

    rpc.send(cmd)
  end)
end

--- Send a prompt directly to pi (no input dialog).
--- If text matches a named prompt from config, it expands it.
---@param text string
---@param opts? { context?: pi.Context, submit?: boolean }
function M.prompt(text, opts)
  opts = opts or {}

  local config = require("pi.config")
  local context_mod = require("pi.context")

  -- Check if text is a named prompt key
  local prompt_def = config.opts.prompts[text]
  if prompt_def then
    text = prompt_def.text
  end

  local ctx = opts.context or context_mod.Context.new()
  local resolved = context_mod.resolve(text, ctx)
  ctx:clear()

  local mode = config.opts.mode or "rpc"
  if mode == "terminal" then
    require("pi.terminal").send(resolved, { submit = opts.submit ~= false })
  else
    M._send_resolved(resolved)
  end
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

  -- Add pi extension commands (from RPC) if available
  local mode = config.opts.mode or "rpc"
  if mode == "rpc" then
    local rpc = require("pi.rpc")
    if rpc.is_ready() then
      rpc.request({ type = "get_commands" }, function(response)
        if response.success and response.data and response.data.commands then
          for _, cmd in ipairs(response.data.commands) do
            items[#items + 1] = {
              label = "/" .. cmd.name .. ": " .. (cmd.description or ""),
              kind = "command",
              name = cmd.name,
            }
          end
        end
        M._show_picker(items, ctx)
      end)
      return
    end
  end

  M._show_picker(items, ctx)
end

--- Show the action picker with the given items.
---@param items table[]
---@param ctx pi.Context
function M._show_picker(items, ctx)
  -- Add control actions
  items[#items + 1] = { label = "[control] abort: Cancel pi's current operation", kind = "control", action = "abort" }
  items[#items + 1] = { label = "[control] toggle: Toggle pi panel", kind = "control", action = "toggle" }

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
      local context_mod = require("pi.context")
      local resolved = context_mod.resolve(selected.text, ctx)
      ctx:clear()
      M._send_resolved(resolved)
    elseif selected.kind == "command" then
      ctx:clear()
      -- Send as /command via prompt
      M._send_resolved("/" .. selected.name)
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

--- Open a model picker to switch models.
function M.pick_model()
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    vim.notify("Pi: RPC not connected", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "get_available_models" }, function(response)
    if not response.success or not response.data or not response.data.models then
      vim.notify("Pi: failed to get models", vim.log.levels.ERROR)
      return
    end

    local models = response.data.models
    local labels = {}
    for _, model in ipairs(models) do
      local cost_str = ""
      if model.cost then
        cost_str = string.format(" ($%.1f/%.1f per MTok)", model.cost.input or 0, model.cost.output or 0)
      end
      local ctx_str = ""
      if model.contextWindow then
        ctx_str = string.format(" [%dk ctx]", model.contextWindow / 1000)
      end
      labels[#labels + 1] = string.format(
        "%s (%s)%s%s",
        model.name or model.id,
        model.provider or "unknown",
        ctx_str,
        cost_str
      )
    end

    vim.ui.select(labels, { prompt = "Select Model:" }, function(_, idx)
      if not idx then
        return
      end
      local selected = models[idx]
      rpc.request(
        { type = "set_model", provider = selected.provider, modelId = selected.id },
        function(resp)
          if resp.success then
            vim.notify(string.format("Pi: switched to %s", selected.name or selected.id))
            -- Update events state
            require("pi.events").refresh_state()
          else
            vim.notify("Pi: failed to switch model: " .. (resp.error or "unknown"), vim.log.levels.ERROR)
          end
        end
      )
    end)
  end)
end

--- Cycle to the next model.
function M.cycle_model()
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    vim.notify("Pi: RPC not connected", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "cycle_model" }, function(response)
    if response.success and response.data and response.data.model then
      local model = response.data.model
      local thinking = response.data.thinkingLevel or ""
      vim.notify(string.format("Pi: %s [%s]", model.name or model.id, thinking))
      require("pi.events").refresh_state()
    end
  end)
end

--- Cycle thinking level.
function M.cycle_thinking()
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    vim.notify("Pi: RPC not connected", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "cycle_thinking_level" }, function(response)
    if response.success and response.data then
      local level = response.data.level or "off"
      vim.notify("Pi: thinking → " .. level)
      require("pi.events").refresh_state()
    elseif response.success then
      vim.notify("Pi: model does not support thinking levels", vim.log.levels.INFO)
    end
  end)
end

--- Start a new session.
function M.new_session()
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    vim.notify("Pi: RPC not connected", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "new_session" }, function(response)
    if response.success then
      if response.data and response.data.cancelled then
        vim.notify("Pi: new session cancelled by extension", vim.log.levels.INFO)
      else
        vim.notify("Pi: new session started")
        local chat = require("pi.chat")
        chat.clear()
        require("pi.events").refresh_state()
      end
    else
      vim.notify("Pi: failed to start new session: " .. (response.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

--- Get session stats.
---@param callback? fun(stats: table)
function M.session_stats(callback)
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    vim.notify("Pi: RPC not connected", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "get_session_stats" }, function(response)
    if response.success and response.data then
      local stats = response.data
      if callback then
        callback(stats)
      else
        local cost = stats.cost or 0
        local tokens = stats.tokens or {}
        vim.notify(string.format(
          "Pi session: %d msgs, %d tool calls | %dk tokens (in: %dk, out: %dk, cache: %dk) | cost: $%.4f",
          stats.totalMessages or 0,
          stats.toolCalls or 0,
          (tokens.total or 0) / 1000,
          (tokens.input or 0) / 1000,
          (tokens.output or 0) / 1000,
          (tokens.cacheRead or 0) / 1000,
          cost
        ))
      end
    end
  end)
end

--- Export session to HTML.
function M.export_html()
  local rpc = require("pi.rpc")
  if not rpc.is_ready() then
    vim.notify("Pi: RPC not connected", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "export_html" }, function(response)
    if response.success and response.data and response.data.path then
      vim.notify("Pi: exported to " .. response.data.path)
    else
      vim.notify("Pi: export failed: " .. (response.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

--- Abort pi's current operation.
function M.abort()
  local config = require("pi.config")
  if (config.opts.mode or "rpc") == "terminal" then
    require("pi.terminal").send_abort()
  else
    require("pi.rpc").abort()
  end
end

--- Send a compact file reference (path:lines) for the context.
--- In RPC mode, sends the full resolved @this context as a prompt.
--- In terminal mode, sends raw keystrokes of the file reference.
function M.send_context()
  local context_mod = require("pi.context")
  local config = require("pi.config")
  local ctx = context_mod.Context.new()

  if (config.opts.mode or "rpc") == "terminal" then
    -- Terminal mode: send compact reference as raw keystrokes
    local ref = ctx:ref()
    ctx:clear()
    if ref then
      require("pi.terminal").send(ref, { submit = false })
    end
  else
    -- RPC mode: open input with context reference pre-filled
    local ref = ctx:ref()
    ctx:clear()
    if ref then
      M.ask(ref, { context = ctx })
    end
  end
end

--- Create an operator function for dot-repeat support.
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

  if km.model then
    vim.keymap.set("n", km.model, function()
      M.pick_model()
    end, { silent = true, desc = "Pi: Pick model" })
  end

  if km.cycle_model then
    vim.keymap.set("n", km.cycle_model, function()
      M.cycle_model()
    end, { silent = true, desc = "Pi: Cycle model" })
  end

  if km.cycle_thinking then
    vim.keymap.set("n", km.cycle_thinking, function()
      M.cycle_thinking()
    end, { silent = true, desc = "Pi: Cycle thinking level" })
  end
end

return M
