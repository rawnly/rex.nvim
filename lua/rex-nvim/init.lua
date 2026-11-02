local M = {}
local comments = require("rex-nvim.comments")
local prompt = require("rex-nvim.prompt")
local agents = require("rex-nvim.agents")
local dispatch = require("rex-nvim.dispatch")
local ui = require("rex-nvim.ui")

M.config = { prefix = "<leader>a", keymaps = true, clear_after_send = true,
  -- Command (or { cmd, split, ratio, float, side, submit }) to open in a new unfocused split when
  -- there is no agent in the session to send to.
  preferred_agent = nil,
  -- Log timings to an in-memory buffer; view with `:Rex debug log`.
  debug = false,
  -- Where to look for agents: "session" (default; a lone agent in another tab
  -- is still used) or "tab" (only agents in this nvim's tab).
  agent_scope = "session",
}

-- Callback of each default keymap this plugin set, by mode and keys. setup()
-- can run more than once (the sidebar daemon calls it again after the user's
-- config did, #49): a map that is still ours is replaced quietly, while any
-- other map on those keys belongs to the user and is left alone.
local own_maps = {}

local function map(mode, lhs, rhs, desc)
  -- Key own_maps by the raw keys, not lhs, so "<leader>a" and "<Space>a"
  -- (with mapleader = " ") are the same map.
  local keys = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  local id = mode .. keys
  local existing = vim.fn.maparg(keys, mode, false, true)
  -- rhs is a new closure on every setup(), so compare against the one we
  -- stored last time: if the map still runs it, nobody has remapped the keys.
  local ours = own_maps[id] ~= nil and existing.callback == own_maps[id]
  if not vim.tbl_isempty(existing) and not ours then
    vim.notify("rex-nvim: not overriding existing map " .. lhs, vim.log.levels.WARN)
    return
  end
  vim.keymap.set(mode, lhs, rhs, { desc = desc })
  own_maps[id] = rhs
end

function M.setup(config)
  M.config = vim.tbl_deep_extend("force", M.config, config or {})
  if config and config.debug ~= nil then require("rex-nvim.debug").set(config.debug) end
  if M.config.agent_scope ~= "session" and M.config.agent_scope ~= "tab" then
    vim.notify(string.format("rex-nvim: invalid agent_scope %q (expected \"session\" or \"tab\"); using \"session\"",
      tostring(M.config.agent_scope)), vim.log.levels.WARN)
    M.config.agent_scope = "session"
  end
  agents.register(agents.normalize_preferred(M.config.preferred_agent))
  -- Ensure :Rex is registered (also done from plugin/rex-nvim.lua).
  require("rex-nvim.commands").register()
  -- Default keymaps stay opt-out (keymaps = true) for backward compatibility.
  -- Prefer the :Rex command or the Lua API and set keymaps = false to bind
  -- your own; see :help rex-nvim.
  if M.config.keymaps then
    local p = M.config.prefix
    map("x", p .. "c", function() M.comment_selection() end, "rex-nvim: comment selection")
    map("n", p .. "c", function() M.comment_line() end, "rex-nvim: comment line")
    map("n", p .. "l", function() M.list_comments() end, "rex-nvim: list comments")
    map("n", p .. "s", function() M.send_all({ submit = false }) end, "rex-nvim: paste comments to agent")
    map("n", p .. "S", function() M.send_all({ submit = true }) end, "rex-nvim: send comments to agent")
    map("x", p .. "i", function() M.ref_selection() end, "rex-nvim: reference selection at agent cursor")
    map("n", p .. "i", function() M.ref_line() end, "rex-nvim: reference line at agent cursor")
  end
end

-- Internal primitive behind comment_line(), comment_selection(), and :Rex comment.
-- span is { start_line = n, end_line = n, cols = { start_col, end_col }? }.
local function comment_span(span)
  local bufnr = vim.api.nvim_get_current_buf()
  ui.input_comment(function(text)
    local id = comments.add(bufnr, span, text)
    ui.decorate(id)
  end)
end

function M.comment_range(start_line, end_line)
  comment_span({ start_line = start_line, end_line = end_line })
end

function M.comment_selection()
  vim.cmd([[execute "normal! \<esc>"]]) -- materialize '< '> marks
  comment_span(ui.visual_region())
end

function M.comment_line()
  local l = vim.api.nvim_win_get_cursor(0)[1]
  M.comment_range(l, l)
end

-- Edit a comment's text in place (undecorate → edit → re-decorate so the callout
-- reflects the new text). `on_done` (optional) fires after the input closes.
function M.edit_comment(c, on_done)
  vim.ui.input({ prompt = "Edit comment: ", default = c.text }, function(t)
    if t and t ~= "" and t ~= c.text then
      ui.undecorate(c.id)
      comments.edit(c.id, t)
      ui.decorate(c.id)
    end
    if on_done then
      on_done()
    end
  end)
end

function M.delete_comment(c)
  ui.undecorate(c.id)
  comments.delete(c.id)
end

-- Interactive list: hover auto-jumps to each comment, <CR> edits, `d` deletes,
-- `q`/<Esc> closes. No secondary jump/edit/delete menu.
function M.list_comments()
  ui.comment_list({
    edit = function(c, refresh)
      M.edit_comment(c, refresh)
    end,
    delete = function(c)
      M.delete_comment(c)
    end,
  })
end

function M._git_context(cwd)
  local ok, r = pcall(function()
    return vim.system({ "git", "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD" },
      { text = true, cwd = cwd }):wait()
  end)
  if not ok or r.code ~= 0 then return nil end
  local root, branch = r.stdout:match("([^\n]*)\n([^\n]*)")
  if not root then return nil end
  return string.format("repo: %s, branch: %s",
    vim.fn.fnamemodify(vim.trim(root), ":t"), vim.trim(branch))
end

-- Single funnel for every send (pending comments and bare references alike), so
-- the agent resolution, the picker fallback, and the "agent is working" warning
-- all live in exactly one place. `build_payload(agent)` runs once the agent is
-- resolved -- paths are shortened against that agent's cwd. `on_sent(agent,
-- payload)` runs only after a successful dispatch.
local starting = false

local function deliver_to_agent(build_payload, opts, on_sent)
  local dbg = require("rex-nvim.debug")
  if starting then
    vim.notify("rex-nvim: agent is still starting — try again in a moment", vim.log.levels.WARN)
    return
  end
  dbg.begin("deliver")
  local agent_list, err = agents.list()
  dbg.log("initial agents.list: %d agent(s)", agent_list and #agent_list or 0)
  if not agent_list then
    vim.notify("rex-nvim: " .. err, vim.log.levels.ERROR)
    return
  end
  if M.config.agent_scope == "tab" then
    agent_list = vim.tbl_filter(function(a) return a.same_window end, agent_list)
  end
  -- `fresh` = we just spawned it: its screen may still be a startup dialog
  -- (trust prompt, login), so only submit after verifying the paste landed.
  local function deliver(agent, fresh, auto_submit)
    if agent.status == "working" then
      vim.notify("rex-nvim: " .. agents.display(agent) .. " is working — sending anyway", vim.log.levels.WARN)
    end
    local payload = build_payload(agent)
    if not payload then return end
    local send_opts = opts
    if fresh then send_opts = vim.tbl_extend("force", opts or {}, { submit = false }) end
    local before = fresh and agents.capture(agent.block_id) or nil
    -- A freshly started agent can look settled (stable screen) before its input
    -- box exists, and a paste sent then is dropped. Unchanged screen after the
    -- paste means nothing landed, so resending is safe: retry a few times.
    local attempts_left = fresh and 4 or 1
    local function attempt()
      attempts_left = attempts_left - 1
      dbg.log("dispatching %d bytes to %s", #payload, agent.block_id)
      local ok, derr = dispatch.send(agent.block_id, payload, send_opts)
      dbg.log("dispatch done (ok=%s)", tostring(ok))
      if not ok then
        vim.notify("rex-nvim: " .. derr, vim.log.levels.ERROR)
        return
      end
      if not fresh then return on_sent(agent, payload) end
      vim.defer_fn(function()
        if agents.capture(agent.block_id) == before then
          if attempts_left > 0 then
            dbg.log("paste not taken; retrying (%d left)", attempts_left)
            return vim.defer_fn(attempt, 700)
          end
          vim.notify("rex-nvim: " .. agent.title .. " did not take the paste (still on its startup screen?) — comments kept",
            vim.log.levels.ERROR)
          return
        end
        if auto_submit and opts and opts.submit then
          local sok, serr = dispatch.submit(agent.block_id)
          dbg.log("auto-submit (ok=%s)", tostring(sok))
          if not sok then vim.notify("rex-nvim: " .. serr, vim.log.levels.ERROR) end
          return on_sent(agent, payload)
        end
        on_sent(agent, payload)
        if opts and opts.submit then
          vim.notify("rex-nvim: agent was just started — pasted but not submitted (submit = false); review and press Enter",
            vim.log.levels.WARN)
        end
      end, 300)
    end
    attempt()
  end
  if #agent_list == 0 then
    local preferred = agents.normalize_preferred(M.config.preferred_agent)
    if not preferred then
      local where = M.config.agent_scope == "tab" and "in this tab" or "in this Rex session"
      vim.notify("rex-nvim: no agents found " .. where, vim.log.levels.WARN)
      return
    end
    local block_id, serr = agents.spawn(preferred)
    if not block_id then
      vim.notify("rex-nvim: " .. serr, vim.log.levels.ERROR)
      return
    end
    vim.notify("rex-nvim: starting " .. preferred.cmd .. "…")
    starting = true
    agents.await(block_id, nil, function(agent, aerr)
      starting = false
      if not agent then
        vim.notify("rex-nvim: " .. aerr, vim.log.levels.ERROR)
        return
      end
      deliver(agent, true, preferred.submit)
    end)
    return
  end
  -- Skip the picker when the target is unambiguous (the common one-agent case);
  -- fall back to the picker only when 2+ agents could plausibly be meant.
  local agent = agents.resolve(agent_list)
  if agent then
    deliver(agent)
  else
    ui.pick_agent(agent_list, deliver)
  end
end

function M.send_all(opts)
  local first = comments.list()
  if #first == 0 then
    vim.notify("rex-nvim: no comments to send", vim.log.levels.INFO)
    return
  end
  local first_file = first[1].file
  local cwd = first_file ~= "" and vim.fn.fnamemodify(first_file, ":h") or nil
  local header_context = M._git_context(cwd)
  local sent = {}
  deliver_to_agent(function(agent)
    -- Read comments now, not before an async wait, so edits/deletes made while
    -- an agent was starting are respected.
    sent = comments.list()
    if #sent == 0 then
      vim.notify("rex-nvim: no comments to send", vim.log.levels.INFO)
      return nil
    end
    local items = {}
    for _, c in ipairs(sent) do
      table.insert(items, { comment = c, snippet = comments.snippet(c.id) })
    end
    return prompt.format(items, { header_context = header_context, cwd = agent.cwd })
  end, opts, function(agent)
    if M.config.clear_after_send then
      for _, c in ipairs(sent) do
        -- Keep comments edited after the snapshot was sent.
        local now = comments.get(c.id)
        if not now or now.text == c.text then M.delete_comment(c) end
      end
    end
    vim.notify(string.format("rex-nvim: sent %d comment(s) to %s", #sent, agent.title))
  end)
end

-- Range primitive behind ref_line(), ref_selection(), and :Rex ref. Sends a
-- bare `path:line` citation and nothing else -- no comment, no code, no header,
-- and never a submit -- so it lands in the middle of a message you are still
-- typing. Pending comments are untouched.
function M.ref_range(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    vim.notify("rex-nvim: buffer has no file to reference", vim.log.levels.WARN)
    return
  end
  local item = { file = file, start_line = start_line, end_line = end_line }
  deliver_to_agent(function(agent)
    return prompt.format_ref(item, { cwd = agent.cwd })
  end, { submit = false }, function(_, payload)
    vim.notify("rex-nvim: referenced " .. vim.trim(payload))
    -- A reference points at the file on disk, so unwritten changes are
    -- invisible to whoever opens it. Worth saying out loud; not worth blocking
    -- over. Only after a send, so a cancelled picker stays silent.
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
      vim.notify("rex-nvim: buffer has unsaved changes — the agent reads the file on disk",
        vim.log.levels.WARN)
    end
  end)
end

function M.ref_selection()
  vim.cmd([[execute "normal! \<esc>"]]) -- materialize '< '> marks
  local s, e = ui.visual_range()
  M.ref_range(s, e)
end

function M.ref_line()
  local l = vim.api.nvim_win_get_cursor(0)[1]
  M.ref_range(l, l)
end

function M.statusline()
  local n = #comments.list()
  return n == 0 and "" or ("● " .. n)
end

return M
