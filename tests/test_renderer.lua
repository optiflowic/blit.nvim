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
