local rpc = require("rex-nvim.rpc")

-- Undo the client mask so a client frame reads like a server frame.
local function unmask(frame)
  local b2 = frame:byte(2)
  local len, off = bit.band(b2, 0x7F), 3
  if len == 126 then off = 5 elseif len == 127 then off = 11 end
  local mask = { frame:byte(off, off + 3) }
  local out = {}
  for i = off + 4, #frame do
    out[#out + 1] = string.char(bit.bxor(frame:byte(i), mask[(i - off - 4) % 4 + 1]))
  end
  return string.char(frame:byte(1), bit.band(b2, 0x7F)) .. frame:sub(3, off - 1) .. table.concat(out)
end

T.test("rpc: frames round-trip at every length encoding", function()
  for _, n in ipairs({ 0, 5, 125, 126, 70000 }) do
    local data = string.rep("x", n)
    local frames, rest = rpc._unframe(unmask(rpc._frame(1, data)))
    T.eq(rest, "")
    T.eq(#frames, 1)
    T.eq(frames[1].data, data, "length " .. n)
    T.eq(frames[1].opcode, 1)
    T.ok(frames[1].fin)
  end
end)

T.test("rpc: client frames are masked", function()
  local f = rpc._frame(1, "hello")
  T.ok(bit.band(f:byte(2), 0x80) ~= 0)
end)

T.test("rpc: unframe waits for a partial frame", function()
  local whole = unmask(rpc._frame(1, "hello world"))
  local frames, rest = rpc._unframe(whole:sub(1, 6))
  T.eq(#frames, 0)
  T.eq(rest, whole:sub(1, 6))
end)

T.test("rpc: no REX_SERVER is an error, not a hang", function()
  local saved = vim.env.REX_SERVER
  vim.env.REX_SERVER = ""
  rpc._reset()
  local r, err = rpc.call(nil, "server.version", nil)
  vim.env.REX_SERVER = saved
  rpc._reset()
  T.eq(r, nil)
  T.ok(err:match("REX_SERVER"))
end)

-- Against the real server, when there is one.
if vim.env.REX_SERVER and vim.env.REX_SERVER ~= "" and (vim.env.REX_SESSION or vim.env.REX_BLOCK) then
  T.test("rpc: live server answers and lists this session's blocks", function()
    rpc._reset()
    local v = assert(rpc.call(nil, "server.version", nil))
    T.ok(v.api_revision)
    local s = assert(rpc.session())
    local listed = assert(rpc.call(s, "session.list_blocks", { session_id = s }))
    T.ok(#listed.blocks >= 1)
  end)

  T.test("rpc: reconnects after the connection drops", function()
    rpc._reset()
    assert(rpc.call(nil, "server.version", nil))
    rpc._drop_for_test()
    vim.wait(200)
    T.ok(rpc.call(nil, "server.version", nil))
  end)
end
