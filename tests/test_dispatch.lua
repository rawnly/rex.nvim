local dispatch = require("rex-nvim.dispatch")

local function recorder(fail_on)
  local calls = {}
  return calls, function(argv)
    table.insert(calls, argv)
    if fail_on and #calls == fail_on then return { code = 1, stdout = "", stderr = "boom" } end
    return { code = 0, stdout = "", stderr = "" }
  end
end

T.test("dispatch: paste mode pastes text only, no Enter", function()
  local calls, exec = recorder()
  local ok = dispatch.send("b:1", "line1\nline2", { submit = false }, exec)
  T.ok(ok)
  T.eq(calls, { { "rex", "send", "-b", "b:1", "\27[200~line1\nline2\27[201~" } })
end)

T.test("dispatch: submit mode pastes then presses Enter", function()
  local calls, exec = recorder()
  local ok = dispatch.send("b:1", "hi", { submit = true }, exec)
  T.ok(ok)
  T.eq(calls, {
    { "rex", "send", "-b", "b:1", "\27[200~hi\27[201~" },
    { "rex", "send-key", "-b", "b:1", "enter" },
  })
end)

T.test("dispatch: failed send returns err and skips Enter", function()
  local calls, exec = recorder(1)
  local ok, err = dispatch.send("b:1", "hi", { submit = true }, exec)
  T.eq(ok, false)
  T.ok(err:match("boom"))
  T.eq(#calls, 1)
end)

T.test("dispatch: failed send-key returns err", function()
  local _, exec = recorder(2)
  local ok, err = dispatch.send("b:1", "hi", { submit = true }, exec)
  T.eq(ok, false)
  T.ok(err:match("send%-key"))
end)
