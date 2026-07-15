local renderer = require("blit.renderer")

local ESC = string.char(27)

local tmp_path
local opened_wins

local function make_png_file()
  tmp_path = vim.fn.tempname() .. ".png"
  local f = io.open(tmp_path, "wb")
  f:write(string.rep("x", 32))
  f:close()
end

local function remove_png_file()
  if tmp_path then
    os.remove(tmp_path)
    tmp_path = nil
  end
end

local captured

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      renderer._reset()
      captured = {}
      opened_wins = {}
      renderer._write_fn = function(sequences)
        table.insert(captured, sequences)
        return true
      end
      renderer._detect_fn = function()
        return { terminal = "kitty", tmux = false, gui_embed = false, supported = true }
      end
      make_png_file()
    end,
    post_case = function()
      renderer._reset()
      remove_png_file()
      for _, win in ipairs(opened_wins) do
        pcall(vim.api.nvim_win_close, win, true)
      end
      opened_wins = {}
    end,
  },
})

-- Floating windows give deterministic screen row/col bounds independent of
-- the host terminal's actual size, so visibility math is testable exactly.
---@param lines string[]
---@param win_width integer
---@param win_height integer
---@return integer buf
---@return integer win
local function setup_floating(lines, win_width, win_height)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = win_width,
    height = win_height,
    style = "minimal",
  })
  table.insert(opened_wins, win)
  return buf, win
end

---@param n integer
---@return string[]
local function numbered_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = "line " .. i
  end
  return lines
end

T["fully_within"] = MiniTest.new_set()

T["fully_within"]["anchor at lower bound with exact span fits"] = function()
  MiniTest.expect.equality(renderer.fully_within(5, 3, 5, 7), true)
end

T["fully_within"]["anchor + span - 1 exceeds bound_end"] = function()
  MiniTest.expect.equality(renderer.fully_within(5, 4, 5, 7), false)
end

T["fully_within"]["anchor before bound_start"] = function()
  MiniTest.expect.equality(renderer.fully_within(4, 3, 5, 7), false)
end

T["fully_within"]["anchor 0 is never visible"] = function()
  MiniTest.expect.equality(renderer.fully_within(0, 1, 1, 10), false)
end

T["fully_within"]["negative anchor is never visible"] = function()
  MiniTest.expect.equality(renderer.fully_within(-1, 1, 1, 10), false)
end

T["cache_key"] = MiniTest.new_set()

T["cache_key"]["combines path and mtime"] = function()
  local key = renderer.cache_key("/a/b.png", { sec = 100, nsec = 42 })
  MiniTest.expect.equality(key, "/a/b.png:100.42")
end

T["cache_key"]["differs across mtimes"] = function()
  local k1 = renderer.cache_key("/a/b.png", { sec = 100, nsec = 0 })
  local k2 = renderer.cache_key("/a/b.png", { sec = 101, nsec = 0 })
  MiniTest.expect.no_equality(k1, k2)
end

T["show"] = MiniTest.new_set()

T["show"]["fully visible: transmits and displays"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local handle, err =
    renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2, col = 0 })

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(handle), "table")
  MiniTest.expect.equality(handle.visible, true)

  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=T", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(ESC .. "7", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(ESC .. "8", 1, true) ~= nil, true)

  local ns = vim.api.nvim_create_namespace("blit")
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, handle.extmark_id, {})
  MiniTest.expect.equality(#mark > 0, true)
end

T["show"]["off-screen anchor: transmit-only, not displayed"] = function()
  local buf, win = setup_floating(numbered_lines(50), 20, 5)

  local handle, err =
    renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 40, col = 0 })

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(handle.visible, false)

  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=t,", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find("a=T", 1, true), nil)
end

T["show"]["cache hit on idle entry places without retransmitting"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local first = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  MiniTest.expect.equality(first.visible, true)
  renderer.clear(first)

  captured = {}
  local second = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  MiniTest.expect.equality(second.visible, true)
  MiniTest.expect.equality(second.id, first.id)

  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=T", 1, true), nil)
  MiniTest.expect.equality(all:find("a=p", 1, true) ~= nil, true)
end

T["show"]["active cache entry forces a fresh id, never relocates"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local first = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  local second = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 4 })

  MiniTest.expect.no_equality(first.id, second.id)
end

T["show"]["rejects a non-positive width/height"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local ok =
    pcall(renderer.show, tmp_path, { width = 0, height = 3, buf = buf, win = win, lnum = 2 })
  MiniTest.expect.equality(ok, false)
end

T["clear"] = MiniTest.new_set()

T["clear"]["deletes placement and extmark"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })

  captured = {}
  renderer.clear(handle)

  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")

  local ns = vim.api.nvim_create_namespace("blit")
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, handle.extmark_id, {})
  MiniTest.expect.equality(#mark, 0)
end

T["clear_all"] = MiniTest.new_set()

T["clear_all"]["clears every active handle"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 5 })

  MiniTest.expect.equality(#renderer._handles, 2)
  renderer.clear_all()
  MiniTest.expect.equality(#renderer._handles, 0)
end

T["redraw"] = MiniTest.new_set()

T["redraw"]["hides once the window shrinks below the reserved rows"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 6, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)

  vim.api.nvim_win_set_config(
    win,
    { relative = "editor", row = 0, col = 0, width = 20, height = 5 }
  )
  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })

  vim.wait(500, function()
    return #captured > 0
  end)

  MiniTest.expect.equality(handle.visible, false)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")
end

return T
