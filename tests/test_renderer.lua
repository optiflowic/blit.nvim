local renderer = require("blit.renderer")

local ESC = string.char(27)

local tmp_path
local opened_wins

local PNG_NATIVE_WIDTH = 100
local PNG_NATIVE_HEIGHT = 50

---@param n integer
---@return string
local function u32be(n)
  return string.char(
    math.floor(n / 0x1000000) % 0x100,
    math.floor(n / 0x10000) % 0x100,
    math.floor(n / 0x100) % 0x100,
    n % 0x100
  )
end

-- A minimal but structurally valid PNG: signature + one IHDR chunk. No
-- IDAT/IEND, and the CRC bytes are dummy zeros — blit.png.read_ihdr never
-- reads past the IHDR chunk data (see lua/blit/png.lua), so this is
-- sufficient for every test in this file that only needs show() to accept
-- the file and know its native pixel dimensions.
---@param width? integer
---@param height? integer
---@return string
local function png_bytes(width, height)
  local signature = string.char(137, 80, 78, 71, 13, 10, 26, 10)
  local ihdr_data = u32be(width or PNG_NATIVE_WIDTH)
    .. u32be(height or PNG_NATIVE_HEIGHT)
    .. string.char(8, 6, 0, 0, 0)
  return signature .. u32be(13) .. "IHDR" .. ihdr_data .. string.char(0, 0, 0, 0)
end

local function make_png_file()
  tmp_path = vim.fn.tempname() .. ".png"
  local f = io.open(tmp_path, "wb")
  f:write(png_bytes())
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
      renderer._ghostty_settle_ms = 5
      make_png_file()
    end,
    post_case = function()
      renderer._reset()
      remove_png_file()
      for _, win in ipairs(opened_wins) do
        pcall(vim.api.nvim_win_close, win, true)
      end
      opened_wins = {}
      while vim.fn.tabpagenr("$") > 1 do
        pcall(vim.cmd, "tabclose")
      end
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

T["compute_clip"] = MiniTest.new_set()

T["compute_clip"]["fully visible: no clip on either end"] = function()
  local lo, hi, vis = renderer.compute_clip(5, 3, 5, 7)
  MiniTest.expect.equality({ lo, hi, vis }, { 0, 0, 3 })
end

T["compute_clip"]["clipped only at the low (top/left) end"] = function()
  local lo, hi, vis = renderer.compute_clip(3, 5, 5, 10)
  MiniTest.expect.equality({ lo, hi, vis }, { 2, 0, 3 })
end

T["compute_clip"]["clipped only at the high (bottom/right) end"] = function()
  local lo, hi, vis = renderer.compute_clip(8, 5, 5, 10)
  MiniTest.expect.equality({ lo, hi, vis }, { 0, 2, 3 })
end

T["compute_clip"]["clipped at both ends"] = function()
  local lo, hi, vis = renderer.compute_clip(3, 10, 5, 8)
  MiniTest.expect.equality({ lo, hi, vis }, { 2, 4, 4 })
end

T["compute_clip"]["entirely outside bounds: nothing visible"] = function()
  local _, _, vis = renderer.compute_clip(20, 3, 5, 10)
  MiniTest.expect.equality(vis, 0)
end

T["compute_clip"]["anchor <= 0 is never visible"] = function()
  MiniTest.expect.equality({ renderer.compute_clip(0, 3, 1, 10) }, { 0, 0, 0 })
  MiniTest.expect.equality({ renderer.compute_clip(-2, 3, 1, 10) }, { 0, 0, 0 })
end

T["compute_clip"]["agrees with fully_within across the same cases"] = function()
  local cases = {
    { 5, 3, 5, 7 },
    { 5, 4, 5, 7 },
    { 4, 3, 5, 7 },
    { 0, 1, 1, 10 },
    { -1, 1, 1, 10 },
    { 3, 5, 5, 10 },
    { 8, 5, 5, 10 },
    { 20, 3, 5, 10 },
  }
  for _, c in ipairs(cases) do
    local lo, hi, vis = renderer.compute_clip(c[1], c[2], c[3], c[4])
    local matches_fully_within = (lo == 0 and hi == 0 and vis == c[2])
    MiniTest.expect.equality(renderer.fully_within(c[1], c[2], c[3], c[4]), matches_fully_within)
  end
end

T["pixel_crop"] = MiniTest.new_set()

T["pixel_crop"]["no clip: full native size, zero offset"] = function()
  local offset, size = renderer.pixel_crop(0, 0, 10, 100)
  MiniTest.expect.equality({ offset, size }, { 0, 100 })
end

T["pixel_crop"]["low-only clip, evenly divisible"] = function()
  local offset, size = renderer.pixel_crop(3, 0, 10, 100)
  MiniTest.expect.equality({ offset, size }, { 30, 70 })
end

T["pixel_crop"]["high-only clip, evenly divisible"] = function()
  local offset, size = renderer.pixel_crop(0, 4, 10, 100)
  MiniTest.expect.equality({ offset, size }, { 0, 60 })
end

T["pixel_crop"]["both ends clipped, evenly divisible"] = function()
  local offset, size = renderer.pixel_crop(2, 3, 10, 100)
  MiniTest.expect.equality({ offset, size }, { 20, 50 })
end

T["pixel_crop"]["non-divisible rounding"] = function()
  -- total_cells=7, native_px=50, clip_low=2: offset = floor(100/7) = 14,
  -- size = 50 - 14 = 36 (visible span 5/7 * 50 ~= 35.7, rounds up to 36).
  local offset, size = renderer.pixel_crop(2, 0, 7, 50)
  MiniTest.expect.equality({ offset, size }, { 14, 36 })
end

T["pixel_crop"]["native smaller than total cells never yields a non-positive size"] = function()
  local offset, size = renderer.pixel_crop(4, 0, 5, 1)
  MiniTest.expect.equality(offset, 0)
  MiniTest.expect.equality(size >= 1, true)
end

T["pixel_crop"]["single visible cell out of a large span stays >= 1px"] = function()
  local offset, size = renderer.pixel_crop(9, 0, 10, 3)
  MiniTest.expect.equality(size >= 1, true)
  MiniTest.expect.equality(offset + size <= 3, true)
end

T["resolve_cell_size"] = MiniTest.new_set()

T["resolve_cell_size"]["both given: passes through unchanged, no aspect-ratio validation"] = function()
  local width, height, err = renderer.resolve_cell_size(10, 3, 100, 50, 0.5)
  MiniTest.expect.equality({ width, height, err }, { 10, 3, nil })
end

T["resolve_cell_size"]["width given: derives height from the native aspect ratio"] = function()
  local width, height, err = renderer.resolve_cell_size(10, nil, 100, 50, 0.5)
  MiniTest.expect.equality({ width, height, err }, { 10, 3, nil })
end

T["resolve_cell_size"]["height given: derives width from the native aspect ratio"] = function()
  local width, height, err = renderer.resolve_cell_size(nil, 4, 100, 50, 0.5)
  MiniTest.expect.equality({ width, height, err }, { 16, 4, nil })
end

T["resolve_cell_size"]["derived dimension never rounds down to zero, clamps to 1"] = function()
  local width, height, err = renderer.resolve_cell_size(nil, 1, 1, 100, 0.5)
  MiniTest.expect.equality({ width, height, err }, { 1, 1, nil })
end

T["resolve_cell_size"]["neither given: returns an error, no dimensions"] = function()
  local width, height, err = renderer.resolve_cell_size(nil, nil, 100, 50, 0.5)
  MiniTest.expect.equality(width, nil)
  MiniTest.expect.equality(height, nil)
  MiniTest.expect.equality(type(err), "string")
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

T["show"]["ghostty: reuses idle cache entry when terminal size is unchanged"] = function()
  renderer._detect_fn = function()
    return { terminal = "ghostty", tmux = false, gui_embed = false, supported = true }
  end
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local first = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  renderer.clear(first)

  captured = {}
  local second = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })

  MiniTest.expect.equality(second.id, first.id)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=T", 1, true), nil)
  MiniTest.expect.equality(all:find("a=p", 1, true) ~= nil, true)
end

T["show"]["ghostty: drops idle cache entry and retransmits after a terminal resize (issue #24)"] = function()
  renderer._detect_fn = function()
    return { terminal = "ghostty", tmux = false, gui_embed = false, supported = true }
  end
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local first = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  renderer.clear(first)

  local original_lines = vim.o.lines
  vim.o.lines = original_lines + 1
  captured = {}
  local second = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  vim.o.lines = original_lines

  MiniTest.expect.no_equality(second.id, first.id)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=T", 1, true) ~= nil, true)
end

T["show"]["non-ghostty: reuses idle cache entry even after a terminal resize"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local first = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  renderer.clear(first)

  local original_lines = vim.o.lines
  vim.o.lines = original_lines + 1
  captured = {}
  local second = renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  vim.o.lines = original_lines

  MiniTest.expect.equality(second.id, first.id)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=T", 1, true), nil)
end

T["show"]["rejects a non-positive width/height"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local ok =
    pcall(renderer.show, tmp_path, { width = 0, height = 3, buf = buf, win = win, lnum = 2 })
  MiniTest.expect.equality(ok, false)
end

T["show"]["rejects omitting both width and height"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local ok = pcall(renderer.show, tmp_path, { buf = buf, win = win, lnum = 2 })
  MiniTest.expect.equality(ok, false)
end

T["show"]["width-only: derives height from the PNG's native aspect ratio (issue #8)"] = function()
  -- tmp_path is PNG_NATIVE_WIDTH x PNG_NATIVE_HEIGHT (100x50, 2:1) via
  -- make_png_file(); with the default cell_aspect_ratio (0.5), width=10
  -- derives height=3 (see the resolve_cell_size unit tests above for the math).
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local handle, err = renderer.show(tmp_path, { width = 10, buf = buf, win = win, lnum = 2 })

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(handle.geometry.cols, 10)
  MiniTest.expect.equality(handle.geometry.rows, 3)
end

T["show"]["height-only: derives width from the PNG's native aspect ratio (issue #8)"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local handle, err = renderer.show(tmp_path, { height = 4, buf = buf, win = win, lnum = 2 })

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(handle.geometry.cols, 16)
  MiniTest.expect.equality(handle.geometry.rows, 4)
end

T["show"]["cell_aspect_ratio opt overrides the config default"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)

  local handle, err =
    renderer.show(tmp_path, { width = 10, cell_aspect_ratio = 1, buf = buf, win = win, lnum = 2 })

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(handle.geometry.cols, 10)
  MiniTest.expect.equality(handle.geometry.rows, 5)
end

T["show"]["rejects a file that isn't a valid PNG, without writing anything"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local bad_path = vim.fn.tempname() .. ".png"
  local f = io.open(bad_path, "wb")
  f:write(string.rep("x", 32))
  f:close()

  local handle, err =
    renderer.show(bad_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })

  MiniTest.expect.equality(handle, nil)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(#captured, 0)
  os.remove(bad_path)
end

T["show"]["forces a screen redraw before placement (issue #19)"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local order = {}
  renderer._redraw_fn = function()
    table.insert(order, "redraw")
  end
  local original_write_fn = renderer._write_fn
  renderer._write_fn = function(sequences)
    table.insert(order, "write")
    return original_write_fn(sequences)
  end

  local handle, err =
    renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(handle.visible, true)
  MiniTest.expect.equality(order, { "redraw", "write" })
end

T["show"]["re-placing a later handle catches up an earlier handle's stale position (issue #18)"] = function()
  local buf, win = setup_floating(numbered_lines(30), 20, 25)

  local a = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 10, debounce_ms = 5 }
  )
  MiniTest.expect.equality(a.visible, true)

  captured = {}
  local b = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(b.visible, true)
  MiniTest.expect.no_equality(a.id, b.id)

  local function a_was_replaced()
    for _, seq in ipairs(captured) do
      local all = table.concat(seq, "")
      if all:find("a=p", 1, true) and all:find("i=" .. a.id, 1, true) then
        return true
      end
    end
    return false
  end

  vim.wait(500, a_was_replaced)
  MiniTest.expect.equality(a_was_replaced(), true)
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

T["clear"]["self-retries a=d a bounded number of times with no further events (issue #27)"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )

  captured = {}
  renderer.clear(handle)
  MiniTest.expect.equality(#captured, 1)

  -- WezTerm can drop destroy_handle's one-shot a=d with no WinScrolled/
  -- WinResized event ever following to trigger a resend (unlike the
  -- still-tracked invisible-handle path, issue #23) — the retry has to be
  -- self-scheduled to ever fire at all.
  vim.wait(500, function()
    return #captured >= 4
  end)
  MiniTest.expect.equality(#captured, 4)
  for _, seq in ipairs(captured) do
    local all = table.concat(seq, "")
    MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")
  end

  -- The retry budget is bounded: nothing further is sent once it's spent.
  captured = {}
  vim.wait(100)
  MiniTest.expect.equality(#captured, 0)
end

T["clear"]["reusing the id before retries finish cancels the pending retry (issue #27)"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local first = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  renderer.clear(first)

  local second = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  MiniTest.expect.equality(second.id, first.id)

  -- Without cancelling `first`'s outstanding retry on reuse, a delayed
  -- retry would resend a=d for this shared id and delete `second`'s
  -- freshly re-placed image out from under it.
  captured = {}
  vim.wait(200)
  for _, seq in ipairs(captured) do
    local all = table.concat(seq, "")
    MiniTest.expect.equality(all:find("a=d", 1, true), nil)
  end
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

T["redraw"]["hides when the anchor line scrolls past the top edge (issue #28)"] = function()
  -- compute_placement's screenpos() call reports row 0 once the anchor line
  -- itself scrolls above the window, resolving to invisible/hidden —
  -- mirroring the already-covered bottom-edge case (#23) symmetrically for
  -- the top edge.
  local buf, win = setup_floating(numbered_lines(20), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)

  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 5 })
  end)
  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })

  vim.wait(500, function()
    return #captured > 0
  end)

  MiniTest.expect.equality(handle.visible, false)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")
end

T["redraw"]["reissues a=d on every pass while invisible past the top edge (issue #28)"] = function()
  local buf, win = setup_floating(numbered_lines(20), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)

  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 5 })
  end)
  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  vim.wait(500, function()
    return #captured > 0
  end)
  MiniTest.expect.equality(handle.visible, false)
  MiniTest.expect.equality(#captured, 1)

  -- A second redraw pass with the anchor still scrolled past the top edge
  -- must resend the delete rather than skip it because handle.visible is
  -- already false — the same self-healing retry the bottom-edge case
  -- (#23) already relies on for WezTerm's scroll-driven rendering lag.
  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  vim.wait(500, function()
    return #captured > 0
  end)
  MiniTest.expect.equality(handle.visible, false)
  MiniTest.expect.equality(#captured, 1)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")
end

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

T["redraw"]["reissues a=d on every pass while still invisible (issue #23)"] = function()
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
  MiniTest.expect.equality(#captured, 1)

  -- A second redraw pass with the window still too short must resend the
  -- delete rather than skip it because handle.visible is already false —
  -- this is the self-healing retry a terminal that missed/lost the first
  -- a=d (e.g. WezTerm's scroll-driven rendering lag) depends on.
  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  vim.wait(500, function()
    return #captured > 0
  end)
  MiniTest.expect.equality(handle.visible, false)
  MiniTest.expect.equality(#captured, 1)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")
end

T["redraw"]["hides on TabLeave and restores on TabEnter (issue #16)"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)

  captured = {}
  vim.cmd("tabnew")

  vim.wait(500, function()
    return #captured > 0
  end)
  MiniTest.expect.equality(handle.visible, false)
  local hide_all = table.concat(captured[1], "")
  MiniTest.expect.equality(hide_all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")

  captured = {}
  vim.cmd("tabclose")

  vim.wait(500, function()
    return #captured > 0
  end)
  MiniTest.expect.equality(handle.visible, true)
  local show_all = table.concat(captured[1], "")
  MiniTest.expect.equality(show_all:find("a=p", 1, true) ~= nil, true)
  MiniTest.expect.equality(show_all:find("i=" .. handle.id, 1, true) ~= nil, true)
end

T["redraw"]["source-rect crop"] = MiniTest.new_set()

T["redraw"]["source-rect crop"]["bottom-clipped placement crops instead of hiding"] = function()
  local buf, win = setup_floating(numbered_lines(20), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 5, buf = buf, win = win, lnum = 8, debounce_ms = 5 }
  )
  -- anchor screen row 8, virt_lines rows 9-13; window bottom edge is row 10:
  -- rows 9-10 visible (2), rows 11-13 clipped (3).
  MiniTest.expect.equality(handle.visible, true)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=d", 1, true), nil)
  MiniTest.expect.equality(all:find(",r=2", 1, true) ~= nil, true)
  -- Row-clipped, but not column-clipped: y=0/h= (paired, source rect is
  -- always y+h together even when the top offset happens to be 0) appear,
  -- x=/w= (column crop) do not.
  MiniTest.expect.equality(all:find(",h=", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(",x=", 1, true), nil)
  MiniTest.expect.equality(all:find(",w=", 1, true), nil)
end

T["redraw"]["source-rect crop"]["right-clipped placement crops instead of hiding"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 25, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  -- anchor screen col 1, span 25 vs. window right edge col 20: 20 visible, 5 clipped.
  MiniTest.expect.equality(handle.visible, true)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=d", 1, true), nil)
  MiniTest.expect.equality(all:find(",c=20", 1, true) ~= nil, true)
  -- Column-clipped, but not row-clipped: x=0/w= (paired) appear, y=/h=
  -- (row crop) do not.
  MiniTest.expect.equality(all:find(",w=", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(",y=", 1, true), nil)
  MiniTest.expect.equality(all:find(",h=", 1, true), nil)
end

T["redraw"]["source-rect crop"]["fully visible placement never emits crop keys"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  renderer.show(tmp_path, { width = 5, height = 3, buf = buf, win = win, lnum = 2 })
  local all = table.concat(captured[1], "")
  for _, key in ipairs({ ",x=", ",y=", ",w=", ",h=" }) do
    MiniTest.expect.equality(all:find(key, 1, true), nil)
  end
end

T["redraw"]["source-rect crop"]["shows a cropped tail (not a blank gap) while scrolling through the reserved rows (issue #6)"] = function()
  local buf, win = setup_floating(numbered_lines(20), 20, 10)
  vim.wo[win].scrolloff = 0
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 5, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)

  -- Scroll gradually (matching real <C-e>-held-down usage) through the
  -- anchor line's reserved virt_lines block, cursor left on the anchor line
  -- itself (scrolloff=0 lets it be pushed along rather than forcing a jump
  -- scroll — jumping the cursor far away first, e.g. to line 15, makes
  -- Neovim snap the window past the whole block in one non-gradual leap,
  -- skipping every intermediate topfill state entirely; verified empirically
  -- and confirmed the wrong way to drive this). This is the exact scenario
  -- the known limitation described: the anchor line's own screenpos goes to
  -- row 0 (fully scrolled off) partway through, while Neovim's own
  -- rendering still shows the tail of the reserved rows at the window's
  -- top edge.
  local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, true, true)
  for _ = 1, 3 do
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! " .. ctrl_e)
    end)
    vim.cmd("redraw")
  end
  MiniTest.expect.equality(vim.api.nvim_win_call(win, vim.fn.winsaveview).topfill, 3)

  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  vim.wait(500, function()
    return #captured > 0
  end)

  MiniTest.expect.equality(handle.visible, true)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=d", 1, true), nil)
  -- 5-row block, topfill=3 remaining -> 2 rows clipped from the top, 3 visible.
  MiniTest.expect.equality(all:find(",r=3", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(",y=", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(",h=", 1, true) ~= nil, true)
end

T["redraw"]["source-rect crop"]["hides once the reserved block has fully scrolled past (topfill exhausted)"] = function()
  local buf, win = setup_floating(numbered_lines(20), 20, 10)
  vim.wo[win].scrolloff = 0
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 5, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)

  local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, true, true)
  for _ = 1, 6 do
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! " .. ctrl_e)
    end)
    vim.cmd("redraw")
  end
  MiniTest.expect.equality(vim.api.nvim_win_call(win, vim.fn.winsaveview).topfill, 0)

  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  vim.wait(500, function()
    return #captured > 0
  end)

  MiniTest.expect.equality(handle.visible, false)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all, ESC .. "_Ga=d,d=i,i=" .. handle.id .. ESC .. "\\")
end

T["redraw"]["source-rect crop"]["two handles anchored at the same lnum hide instead of risking a wrong crop"] = function()
  local buf, win = setup_floating(numbered_lines(20), 20, 10)
  vim.wo[win].scrolloff = 0
  local handle_a = renderer.show(
    tmp_path,
    { width = 5, height = 5, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  local handle_b = renderer.show(
    tmp_path,
    { width = 5, height = 5, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle_a.visible, true)
  MiniTest.expect.equality(handle_b.visible, true)

  -- Scroll gradually until the window's topline has landed exactly on the
  -- line after the shared anchor, with reserved rows from both handles'
  -- virt_lines still partly showing (winsaveview().topfill > 0) — the exact
  -- scenario where topfill can no longer be attributed to a single handle.
  local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, true, true)
  local view
  for _ = 1, 20 do
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! " .. ctrl_e)
    end)
    vim.cmd("redraw")
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    if view.topline == 2 and view.topfill > 0 then
      break
    end
  end
  MiniTest.expect.equality(view.topline, 2)
  MiniTest.expect.equality(view.topfill > 0, true)

  captured = {}
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  vim.wait(500, function()
    return #captured >= 2
  end)

  MiniTest.expect.equality(handle_a.visible, false)
  MiniTest.expect.equality(handle_b.visible, false)
end

T["redraw"]["wrapped anchor line"] = MiniTest.new_set()

T["redraw"]["wrapped anchor line"]["places virt_lines below the anchor's LAST wrapped row, not its first (issue #7)"] = function()
  -- 45 'x's at window width 20 wraps line 2 across rows 2, 3, 4 — virt_lines
  -- must start at row 5, not row 3 (pos.row + 1 using only the first wrapped row).
  local long_line = string.rep("x", 45)
  local buf, win = setup_floating({ "line 1", long_line, "line 3" }, 20, 15)
  renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find(ESC .. "[5;1H", 1, true) ~= nil, true)
  MiniTest.expect.equality(all:find(ESC .. "[3;1H", 1, true), nil)
end

T["redraw"]["wrapped anchor line"]["hides when the wrap tail scrolls past the window's bottom edge"] = function()
  -- 100 'x's wraps into 5 rows at width 20 (rows 1-5), but the window is only
  -- 3 rows tall: the anchor's first row (1) renders, its last wrapped row
  -- (5) does not — the reserved block is entirely off-screen too.
  local long_line = string.rep("x", 100)
  local buf, win = setup_floating({ long_line, "line 2" }, 20, 3)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 1, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, false)
  local all = table.concat(captured[1], "")
  MiniTest.expect.equality(all:find("a=T", 1, true), nil)
  MiniTest.expect.equality(all:find("a=t,", 1, true) ~= nil, true)
end

---@return boolean
local function any_captured_has(needle)
  for _, seq in ipairs(captured) do
    if table.concat(seq, ""):find(needle, 1, true) then
      return true
    end
  end
  return false
end

T["redraw"]["ghostty: retransmits a still-visible handle after a terminal resize (issue #34)"] = function()
  renderer._detect_fn = function()
    return { terminal = "ghostty", tmux = false, gui_embed = false, supported = true }
  end
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)
  local original_id = handle.id

  -- Kept changed until the retransmit pass has actually run: the settle
  -- timer's own `ghostty_entry_stale` check (issue #34) re-reads
  -- `vim.o.columns` at fire time, so restoring it early would make the
  -- handle's cache entry look fresh again and mask the retransmit.
  local original_columns = vim.o.columns
  vim.o.columns = original_columns + 1
  captured = {}
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win) })

  vim.wait(1000, function()
    return any_captured_has("a=T")
  end)
  vim.o.columns = original_columns

  MiniTest.expect.equality(handle.visible, true)
  MiniTest.expect.no_equality(handle.id, original_id)
  MiniTest.expect.equality(any_captured_has("a=T"), true)
end

T["redraw"]["ghostty: retries a failed retransmit without a further resize event (issue #37)"] = function()
  renderer._detect_fn = function()
    return { terminal = "ghostty", tmux = false, gui_embed = false, supported = true }
  end
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)
  local original_id = handle.id

  local original_columns = vim.o.columns
  vim.o.columns = original_columns + 1
  captured = {}

  -- Fails exactly the first retransmit attempt (simulating, e.g.,
  -- write_all() exhausting its bounded EAGAIN retries — see terminal.lua)
  -- to confirm ghostty_retransmit_pass self-reschedules another attempt
  -- (issue #37) instead of leaving the handle stale until an unrelated
  -- future WinResized/WinScrolled event happens to arrive.
  local transmit_attempts = 0
  renderer._write_fn = function(sequences)
    table.insert(captured, sequences)
    if table.concat(sequences, ""):find("a=T", 1, true) then
      transmit_attempts = transmit_attempts + 1
      if transmit_attempts == 1 then
        return false
      end
    end
    return true
  end

  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win) })

  vim.wait(1000, function()
    return transmit_attempts >= 2
  end)
  vim.o.columns = original_columns

  MiniTest.expect.equality(transmit_attempts, 2)
  MiniTest.expect.equality(handle.visible, true)
  MiniTest.expect.no_equality(handle.id, original_id)
end

T["redraw"]["ghostty: does not retransmit a still-visible handle when size is unchanged"] = function()
  renderer._detect_fn = function()
    return { terminal = "ghostty", tmux = false, gui_embed = false, supported = true }
  end
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)
  local original_id = handle.id

  captured = {}
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win) })

  vim.wait(500, function()
    return #captured > 0
  end)
  -- No stale entry was ever detected, so no settle timer was even
  -- scheduled — waiting past `_ghostty_settle_ms` confirms that rather
  -- than just that the first (reposition) write hasn't arrived yet.
  vim.wait(100)

  MiniTest.expect.equality(handle.visible, true)
  MiniTest.expect.equality(handle.id, original_id)
  MiniTest.expect.equality(any_captured_has("a=T"), false)
  local first_all = table.concat(captured[1], "")
  MiniTest.expect.equality(first_all:find("a=p", 1, true) ~= nil, true)
end

T["redraw"]["non-ghostty: never retransmits a still-visible handle after a resize"] = function()
  local buf, win = setup_floating(numbered_lines(10), 20, 10)
  local handle = renderer.show(
    tmp_path,
    { width = 5, height = 3, buf = buf, win = win, lnum = 2, debounce_ms = 5 }
  )
  MiniTest.expect.equality(handle.visible, true)
  local original_id = handle.id

  local original_columns = vim.o.columns
  vim.o.columns = original_columns + 1
  captured = {}
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win) })

  vim.wait(500, function()
    return #captured > 0
  end)
  vim.wait(100)
  vim.o.columns = original_columns

  MiniTest.expect.equality(handle.visible, true)
  MiniTest.expect.equality(handle.id, original_id)
  MiniTest.expect.equality(any_captured_has("a=T"), false)
  local first_all = table.concat(captured[1], "")
  MiniTest.expect.equality(first_all:find("a=p", 1, true) ~= nil, true)
end

return T
