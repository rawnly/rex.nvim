-- Talks to the Rex server over its control socket ($REX_SERVER): one WebSocket
-- at /api/control speaking rex.control.v1, kept open and reused. Nothing is
-- spawned. Calls are synchronous (vim.wait drives the uv loop).
local M = {}
local uv = vim.uv or vim.loop

M.API_REVISION = 19 -- the revision this plugin was written against
M.timeout_ms = 10000

local conn -- { pipe, buf, pending, attached, next_id, dead, upgraded, msg }

-- WebSocket framing -------------------------------------------------------

-- Client frames must be masked (RFC 6455 5.3).
function M._frame(opcode, data)
  local len = #data
  local hdr
  if len < 126 then
    hdr = string.char(0x80 + opcode, 0x80 + len)
  elseif len < 65536 then
    hdr = string.char(0x80 + opcode, 0xFE, math.floor(len / 256), len % 256)
  else
    local b = {}
    for i = 8, 1, -1 do
      b[i] = len % 256
      len = math.floor(len / 256)
    end
    hdr = string.char(0x80 + opcode, 0xFF, unpack(b))
    len = #data
  end
  local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  local out = {}
  for i = 1, len do
    out[i] = string.char(bit.bxor(data:byte(i), mask[(i - 1) % 4 + 1]))
  end
  return hdr .. string.char(unpack(mask)) .. table.concat(out)
end

-- Pops complete frames off `buf`. Returns the frames ({ fin, opcode, data })
-- and what's left over. Server frames are never masked.
function M._unframe(buf)
  local frames = {}
  while #buf >= 2 do
    local b1, b2 = buf:byte(1, 2)
    local len, off = bit.band(b2, 0x7F), 3
    if len == 126 then
      if #buf < 4 then break end
      len, off = buf:byte(3) * 256 + buf:byte(4), 5
    elseif len == 127 then
      if #buf < 10 then break end
      len = 0
      for i = 3, 10 do len = len * 256 + buf:byte(i) end
      off = 11
    end
    if #buf < off + len - 1 then break end
    table.insert(frames, { fin = bit.band(b1, 0x80) ~= 0, opcode = bit.band(b1, 0x0F), data = buf:sub(off, off + len - 1) })
    buf = buf:sub(off + len)
  end
  return frames, buf
end

-- Connection --------------------------------------------------------------

local function socket_path()
  local s = vim.env.REX_SERVER
  if not s or s == "" then return nil, "REX_SERVER is unset" end
  if not s:match("^unix://") then return nil, "REX_SERVER is not a unix socket: " .. s end
  return vim.uri_decode((s:gsub("^unix://", "")))
end

local function kill(c, why)
  if c.dead then return end
  c.dead = why or "connection closed"
  for _, p in pairs(c.pending) do
    p.done, p.lost = true, true
  end
  if not c.pipe:is_closing() then c.pipe:close() end
end

local function send(c, tbl)
  if c.dead then return end
  c.pipe:write(M._frame(1, vim.json.encode(tbl)), function(err)
    if err then kill(c, "write failed: " .. err) end
  end)
end

local function on_message(c, text)
  local ok, m = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(m) ~= "table" then return end
  if m.type == "welcome" then
    c.welcome = m
  elseif m.type == "response" then
    local p = c.pending[m.id]
    if p then
      c.pending[m.id] = nil
      p.done, p.result, p.err = true, m.payload, m.error
    end
  end -- events and anything else are ignored
end

local function on_data(c, chunk)
  c.buf = c.buf .. chunk
  if not c.upgraded then
    local e = c.buf:find("\r\n\r\n", 1, true)
    if not e then return end
    local status = c.buf:match("^HTTP/1%.1 (%d+)")
    if status ~= "101" then return kill(c, "handshake refused: " .. (c.buf:match("^[^\r]*") or "?")) end
    c.buf, c.upgraded = c.buf:sub(e + 4), true
  end
  local frames
  frames, c.buf = M._unframe(c.buf)
  for _, f in ipairs(frames) do
    if f.opcode == 8 then
      -- Close payload: 2-byte code, then the server's reason (e.g. an API revision mismatch).
      local reason = #f.data > 2 and f.data:sub(3) or ""
      return kill(c, "server closed the connection" .. (reason ~= "" and ": " .. reason or ""))
    end
    if f.opcode == 9 then c.pipe:write(M._frame(10, f.data)) end
    if f.opcode == 1 or f.opcode == 0 then
      c.msg = (f.opcode == 1 and "" or (c.msg or "")) .. f.data
      if f.fin then
        on_message(c, c.msg)
        c.msg = nil
      end
    end
  end
end

local function wait(c, pred)
  local ok = vim.wait(M.timeout_ms, function() return c.dead or pred() end, 5)
  if c.dead then return false, c.dead end
  if not ok then return false, "timed out" end
  return true
end

local function connect()
  local path, perr = socket_path()
  if not path then return nil, perr end
  local c = { pipe = uv.new_pipe(false), buf = "", pending = {}, attached = {}, next_id = 0 }
  c.pipe:connect(path, function(err)
    if err then return kill(c, "cannot reach the Rex server: " .. err) end
    c.pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then return kill(c, rerr) end
      on_data(c, chunk)
    end)
    local key = vim.base64.encode(string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)))
    c.pipe:write(table.concat({
      "GET /api/control HTTP/1.1", "Host: localhost", "Upgrade: websocket", "Connection: Upgrade",
      "Sec-WebSocket-Key: " .. key, "Sec-WebSocket-Version: 13", "Sec-WebSocket-Protocol: rex.control.v1", "", "",
    }, "\r\n"))
  end)
  local ok, err = wait(c, function() return c.upgraded end)
  if not ok then kill(c); return nil, err end
  send(c, {
    type = "hello",
    api_revision = M.API_REVISION,
    api_min_revision = M.API_REVISION,
    client = { kind = "tool", name = "rex-nvim", label = "rex-nvim" },
  })
  ok, err = wait(c, function() return c.welcome ~= nil end)
  if not ok then kill(c); return nil, err end
  return c
end

local function request(c, method, payload)
  c.next_id = c.next_id + 1
  local id = tostring(c.next_id)
  local p = {}
  c.pending[id] = p
  send(c, { type = "request", id = id, method = method, payload = payload })
  if c.dead then p.done, p.lost = true, true end
  return p
end

local function format_err(method, e)
  if type(e) == "table" then return method .. ": " .. (e.message or e.code or vim.inspect(e)) end
  return method .. ": " .. tostring(e)
end

-- Opens (or reuses) the connection and attaches it to `session`.
local function ready(session)
  if not conn or conn.dead then
    local c, err = connect()
    if not c then return nil, err end
    conn = c
  end
  if session and not conn.attached[session] then
    local p = request(conn, "session.attach", { session_id = session })
    local ok, err = wait(conn, function() return p.done end)
    if not ok then return nil, format_err("session.attach", err) end
    if p.err then return nil, format_err("session.attach", p.err) end
    conn.attached[session] = true
  end
  return conn
end

-- Sends every { method, payload } in `calls` at once and waits for all.
-- Returns a list of { result = ..., err = ... }, or nil, err when the
-- connection can't be had. Connection failures are retried once on a fresh
-- connection; a call that was lost in flight is retried only when
-- opts.idempotent is set, since it may have run.
function M.batch(session, calls, opts)
  opts = opts or {}
  local out = {}
  local todo = {}
  for i = 1, #calls do todo[i] = i end
  local last_err
  for _ = 1, 2 do
    local c, err = ready(session)
    if c then
      local inflight = {}
      for _, i in ipairs(todo) do
        inflight[i] = request(c, calls[i][1], calls[i][2])
      end
      wait(c, function()
        for _, p in pairs(inflight) do
          if not p.done then return false end
        end
        return true
      end)
      todo = {}
      for i, p in pairs(inflight) do
        if p.done and not p.lost then
          out[i] = { result = p.result, err = p.err and format_err(calls[i][1], p.err) }
        elseif p.lost and opts.idempotent then
          table.insert(todo, i)
        else
          out[i] = { err = format_err(calls[i][1], p.lost and (c.dead or "connection lost") or "timed out") }
        end
      end
      table.sort(todo)
      if #todo == 0 then return out end
      last_err = c.dead
    else
      last_err = err
    end
  end
  if next(out) == nil then return nil, last_err end
  for _, i in ipairs(todo) do out[i] = { err = format_err(calls[i][1], last_err) } end
  return out
end

-- One call. Returns result or nil, err.
function M.call(session, method, payload, opts)
  local res, err = M.batch(session, { { method, payload } }, opts)
  if not res then return nil, err end
  if res[1].err then return nil, res[1].err end
  return res[1].result == nil and vim.empty_dict() or res[1].result
end

-- The Rex session nvim runs in. Servers from API revision 19 export only
-- REX_BLOCK, so the session is looked up from the block; `rpc` lets tests
-- pass a fake. Returns session_id or nil, err.
function M.session(rpc)
  rpc = rpc or M
  local s, block = vim.env.REX_SESSION, vim.env.REX_BLOCK
  if s and s ~= "" then return s end
  if not block or block == "" then
    return nil, "not running inside a Rex session (REX_SESSION and REX_BLOCK are unset)"
  end
  local res, err = rpc.call(nil, "target.resolve", { kinds = { "session" }, queries = { block } }, { idempotent = true })
  if not res then return nil, err end
  local r = res.results and res.results[1]
  if not r or r.status ~= "resolved" or not r.target or not r.target.session_id then
    return nil, "cannot find the Rex session of " .. block .. (r and r.reason and r.reason ~= "" and ": " .. r.reason or "")
  end
  return r.target.session_id
end

-- Hang up our side; the server closes its side, as when it restarts.
function M._drop_for_test()
  if conn then conn.pipe:shutdown() end
end

function M._reset()
  if conn then kill(conn, "reset") end
  conn = nil
end

return M
