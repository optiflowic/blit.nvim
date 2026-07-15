local terminal = require("blit.terminal")

local original_writer_factory = terminal._writer_factory

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      terminal.reset_writer()
    end,
    post_case = function()
      terminal.reset_writer()
      terminal._writer_factory = original_writer_factory
    end,
  },
})

T["write with an injected writer"] = function()
  local calls = {}
  local writer = function(data)
    table.insert(calls, data)
    return true
  end

  local ok, err = terminal.write({ "a", "b", "c" }, writer)

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(calls, { "a", "b", "c" })
end

T["propagates writer failure without throwing"] = function()
  local calls = {}
  local writer = function(data)
    table.insert(calls, data)
    return nil, "boom"
  end

  local ok, err = terminal.write({ "x", "y" }, writer)

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err, "boom")
  MiniTest.expect.equality(calls, { "x" })
end

T["caches the default writer across calls"] = function()
  local factory_calls = 0
  local write_calls = {}
  terminal._writer_factory = function()
    factory_calls = factory_calls + 1
    return function(data)
      table.insert(write_calls, data)
      return true
    end
  end

  terminal.write({ "a" })
  terminal.write({ "b" })

  MiniTest.expect.equality(factory_calls, 1)
  MiniTest.expect.equality(write_calls, { "a", "b" })
end

T["reset_writer forces the factory to run again"] = function()
  local factory_calls = 0
  terminal._writer_factory = function()
    factory_calls = factory_calls + 1
    return function(_)
      return true
    end
  end

  terminal.write({ "a" })
  terminal.reset_writer()
  terminal.write({ "b" })

  MiniTest.expect.equality(factory_calls, 2)
end

return T
