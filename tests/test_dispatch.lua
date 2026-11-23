local dispatch = require("rex-nvim.dispatch")

local function recorder(fail_on)
  local calls = {}
  return calls, {
    call = function(session, method, payload)
      table.insert(calls, { session, method, payload.block_id, payload.event.type, payload.event.payload })
      if fail_on and #calls == fail_on then return nil, "boom" end
      return {}
    end,
  }
end

local function with_session(fn)
  local saved = vim.env.REX_SESSION
  vim.env.REX_SESSION = "s:1"
  local ok, err = pcall(fn)
  vim.env.REX_SESSION = saved
  if not ok then error(err, 0) end
end

T.test("dispatch: paste mode pastes text only, no Enter", function()
  with_session(function()
    local calls, rpc = recorder()
    T.ok(dispatch.send("b:1", "line1\nline2", { submit = false }, rpc))
    T.eq(calls, { { "s:1", "block.event", "b:1", "paste", { text = "line1\nline2" } } })
  end)
end)

T.test("dispatch: submit mode pastes then presses Enter", function()
  with_session(function()
    local calls, rpc = recorder()
    T.ok(dispatch.send("b:1", "hi", { submit = true }, rpc))
    T.eq(#calls, 2)
    T.eq(calls[1][4], "paste")
    T.eq(calls[2][4], "key")
    T.eq(calls[2][5].key, "enter")
    T.eq(calls[2][5].text, "\r")
  end)
end)

T.test("dispatch: failed paste returns err and skips Enter", function()
  with_session(function()
    local calls, rpc = recorder(1)
    local ok, err = dispatch.send("b:1", "hi", { submit = true }, rpc)
    T.eq(ok, false)
    T.ok(err:match("boom"))
    T.eq(#calls, 1)
  end)
end)

T.test("dispatch: failed Enter returns err", function()
  with_session(function()
    local _, rpc = recorder(2)
    local ok, err = dispatch.send("b:1", "hi", { submit = true }, rpc)
    T.eq(ok, false)
    T.ok(err:match("enter"))
  end)
end)
