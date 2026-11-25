-- Starts the preferred agent beside nvim when no agent is found, and hands it
-- back once it is ready to take a paste.
local M = {}

M.poll_ms = 100
M.timeout_ms = 20000

-- split name -> session.new_split direction and side
local SPLITS = {
  right = { "horizontal", "after" },
  left = { "horizontal", "before" },
  below = { "vertical", "after" },
  above = { "vertical", "before" },
}

-- Floating layer bounds { x, y, w, h } hugging the `split` edge, r wide/tall.
local function bounds(split, r)
  if split == "right" then return { 1 - r, 0, r, 1 } end
  if split == "left" then return { 0, 0, r, 1 } end
  if split == "below" then return { 0, 1 - r, 1, r } end
  return { 0, 0, 1, r }
end

-- `spec` is a command string, an argv list, or
-- { cmd = string|list, split = "right", ratio = 50, float = false, submit = false }.
function M.normalize(spec)
  if type(spec) == "string" or (type(spec) == "table" and spec[1]) then spec = { cmd = spec } end
  if type(spec) ~= "table" then return nil, "preferred_agent must be a command or a table" end
  local cmd = spec.cmd
  if type(cmd) == "string" then cmd = vim.split(cmd, "%s+", { trimempty = true }) end
  if type(cmd) ~= "table" or not cmd[1] then return nil, "preferred_agent needs a cmd" end
  local split = spec.split or "right"
  if not SPLITS[split] then return nil, "preferred_agent.split must be right, left, below or above" end
  local ratio = spec.ratio or 50
  if type(ratio) ~= "number" or ratio <= 0 or ratio >= 100 then
    return nil, "preferred_agent.ratio must be a percent between 0 and 100"
  end
  return {
    cmd = cmd,
    name = vim.fs.basename(cmd[1]),
    split = split,
    ratio = ratio,
    float = spec.float == true,
    submit = spec.submit == true,
  }
end

-- The new pane's size in cells, worked out from nvim's pane `me` (which the
-- Rex app owns, so its size is real): a split takes ratio of nvim's pane, a
-- float ratio of the tab, taken to be about the size of nvim's pane.
function M.estimate(me, split, r, float)
  if not me or not me.columns or not me.rows then return nil end
  local horizontal = split == "right" or split == "left"
  local gap = float and 0 or 1 -- a split loses a cell to the divider
  local size = {
    columns = horizontal and math.max(1, math.floor(me.columns * r) - gap) or me.columns,
    rows = horizontal and me.rows or math.max(1, math.floor(me.rows * r) - gap),
  }
  if me.cell_width_px and me.cell_height_px then
    size.cell_width_px, size.cell_height_px = me.cell_width_px, me.cell_height_px
  end
  return size
end

local function bracketed_paste(modes)
  for _, m in ipairs((modes or {}).modes or {}) do
    if m.name == "bracketed_paste" then return m.set end
  end
  return false
end

-- Calls on_ready(agent) once the agent turns on bracketed paste (it's reading
-- input then), or on_ready(nil, err) if it exits or never gets there.
function M.start(spec, on_ready, rpc)
  rpc = rpc or require("rex-nvim.rpc")
  local opts, err = M.normalize(spec)
  if not opts then return on_ready(nil, err) end
  local session, serr = require("rex-nvim.rpc").session(rpc)
  if not session then return on_ready(nil, serr) end
  local here = vim.env.REX_BLOCK or ""
  local name, cwd, r = opts.name, vim.fn.getcwd(), opts.ratio / 100
  local direction, side = unpack(SPLITS[opts.split])
  local me = here ~= "" and rpc.call(session, "block.method", { session_id = session, block_id = here, method = "size" }) or nil
  local created
  created, err = rpc.call(session, "session.new_split", {
    session_id = session,
    anchor_id = here ~= "" and here or nil,
    direction = direction,
    side = side,
    ratio = side == "after" and 1 - r or r, -- ratio is the "before" part's share
    focus = false,
    layout = { block = {
      flavor = "com.superlogical.terminal.shell",
      label = name,
      options = { command = opts.cmd, cwd = cwd },
    } },
  })
  if not created then return on_ready(nil, "could not start " .. name .. ": " .. err) end
  local block_id = created.block_ids[1]
  if opts.float then
    local _, ferr = rpc.call(session, "session.float_block", { session_id = session, block_id = block_id, bounds = bounds(opts.split, r) })
    if ferr then vim.notify("rex-nvim: could not float " .. name .. ": " .. ferr, vim.log.levels.WARN) end
  end
  -- We created the pane, so we own it, and only its owner sizes it: left
  -- alone it starts at 80x24 whatever space it gets. Give it up so the Rex app
  -- can take it (it does when you use the pane), and size it until then.
  rpc.call(session, "session.disown_block", { session_id = session, block_ids = { block_id } })
  local size = M.estimate(me, opts.split, r, opts.float)
  if size then
    rpc.call(session, "block.method", { session_id = session, block_id = block_id, method = "resize", args = size })
  end
  local agent = { block_id = block_id, same_window = true, kind = name, program = name, status = "idle", cwd = cwd, title = name }

  local deadline = vim.uv.now() + M.timeout_ms
  local function poll()
    local res = rpc.batch(session, {
      { "block.method", { session_id = session, block_id = block_id, method = "modes" } },
      { "block.method", { session_id = session, block_id = block_id, method = "process" } },
    }, { idempotent = true }) or {}
    local proc = (res[2] or {}).result or {}
    if proc.last_exit then
      return on_ready(nil, string.format("%s exited (%s)", name, proc.last_exit.error or proc.last_exit.exit_code))
    end
    if bracketed_paste((res[1] or {}).result) then return on_ready(agent) end
    if vim.uv.now() >= deadline then return on_ready(nil, name .. " did not become ready in time") end
    vim.defer_fn(poll, M.poll_ms)
  end
  poll()
end

return M
