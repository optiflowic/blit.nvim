local terminal = require("blit.terminal")

local original_writer_factory = terminal._writer_factory
local original_fs_open = terminal._fs_open
local original_fs_write = terminal._fs_write

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      terminal.reset_writer()
    end,
    post_case = function()
      terminal.reset_writer()
      terminal._writer_factory = original_writer_factory
      terminal._fs_open = original_fs_open
      terminal._fs_write = original_fs_write
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

T["default writer factory tries /dev/tty first and stops there on success"] = function()
  local opened_paths = {}
  terminal._fs_open = function(path)
    table.insert(opened_paths, path)
    return 7
  end

  local writer, err, close = terminal._writer_factory()

  MiniTest.expect.equality(opened_paths, { "/dev/tty" })
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(writer), "function")
  MiniTest.expect.equality(type(close), "function")
end

T["default writer factory falls back to /dev/fd/1 when /dev/tty is unopenable"] = function()
  local opened_paths = {}
  terminal._fs_open = function(path)
    table.insert(opened_paths, path)
    if path == "/dev/tty" then
      return nil, "ENXIO: no such device or address: /dev/tty"
    end
    return 7
  end

  local writer, err, close = terminal._writer_factory()

  MiniTest.expect.equality(opened_paths, { "/dev/tty", "/dev/fd/1" })
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(writer), "function")
  MiniTest.expect.equality(type(close), "function")
end

T["default writer factory propagates the last error when every path fails"] = function()
  terminal._fs_open = function(path)
    if path == "/dev/tty" then
      return nil, "ENXIO: no such device or address: /dev/tty"
    end
    return nil, "ENOENT: no such file or directory: /dev/fd/1"
  end

  local writer, err, close = terminal._writer_factory()

  MiniTest.expect.equality(writer, nil)
  MiniTest.expect.equality(err, "ENOENT: no such file or directory: /dev/fd/1")
  MiniTest.expect.equality(close, nil)
end

T["default writer retries on EAGAIN and eventually succeeds"] = function()
  terminal._fs_open = function()
    return 7
  end
  local attempts = 0
  terminal._fs_write = function(_, data)
    attempts = attempts + 1
    if attempts < 3 then
      return nil, "EAGAIN: resource temporarily unavailable, write"
    end
    return #data
  end

  local writer = terminal._writer_factory()
  local ok, err = writer("hello")

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(attempts, 3)
end

T["default writer loops on partial writes until fully flushed"] = function()
  terminal._fs_open = function()
    return 7
  end
  local seen_chunks = {}
  terminal._fs_write = function(_, data)
    table.insert(seen_chunks, data)
    return 1
  end

  local writer = terminal._writer_factory()
  local ok, err = writer("abc")

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(seen_chunks, { "abc", "bc", "c" })
end

T["default writer gives up after too many consecutive EAGAINs"] = function()
  terminal._fs_open = function()
    return 7
  end
  terminal._fs_write = function()
    return nil, "EAGAIN: resource temporarily unavailable, write"
  end

  local writer = terminal._writer_factory()
  local ok, err = writer("x")

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:find("EAGAIN") ~= nil, true)
end

T["default writer propagates a non-EAGAIN write error immediately"] = function()
  terminal._fs_open = function()
    return 7
  end
  local attempts = 0
  terminal._fs_write = function()
    attempts = attempts + 1
    return nil, "EIO: i/o error, write"
  end

  local writer = terminal._writer_factory()
  local ok, err = writer("x")

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err, "EIO: i/o error, write")
  MiniTest.expect.equality(attempts, 1)
end

return T
