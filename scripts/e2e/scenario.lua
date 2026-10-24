-- Neovim side of the e2e run. Started by scripts/e2e/run.sh inside the
-- terminal under test; not meant to be run by hand.
--
-- Each step talks to the runner through files in $BLIT_E2E_DIR:
--   req-NNN.json  written here ({ type = "ready" | "calibrate" | "capture" | "resize" | "result" | "quit" | "error" })
--   ack-NNN       written by the runner once the request is handled
--
-- A "capture" request carries where each image should be on screen, in
-- 1-based screen cells. run.sh takes a screenshot and check.py compares it.
-- A "calibrate" request carries where the marker blocks are, which check.py
-- measures cell size and the screen origin from.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

local blit = require("blit")
local renderer = require("blit.renderer")
local terminal = require("blit.terminal")

local dir = assert(os.getenv("BLIT_E2E_DIR"), "BLIT_E2E_DIR is not set")
local fixture = dir .. "/fixture.png"
-- Written by run.sh: the fixture with every color shifted (check.py variant 3).
local variant = dir .. "/variant.png"
local VARIANT = 3
-- Written by the scenario: copies it can overwrite or corrupt.
local swap = dir .. "/swap.png"
local corrupt = dir .. "/corrupt.png"

local IMG_COLS = 8
local IMG_ROWS = 6
-- Calibration marker: a block of cells with a magenta background (check.py's
-- MARKER_INDEX), painted with a highlight so the terminal itself draws it.
local MARKER_HL = "BlitE2EMarker"
local MARKER_COLOR = "#ff00ff"
local MARKER_SIZE = { cols = 4, rows = 2 }
local marker_ns = vim.api.nvim_create_namespace("blit-e2e")
-- Long enough for the debounce, Ghostty's resize settle timer, and a repaint.
local SETTLE_MS = 400
local ACK_TIMEOUT_MS = 30000

local seq = 0
local runner
-- Every batch of escape sequences blit sent, in order (see record_writes).
local writes = {}

local function resume()
  local ok, err = coroutine.resume(runner)
  if not ok then
    seq = seq + 1
    local f = assert(io.open(("%s/req-%03d.json"):format(dir, seq), "w"))
    f:write(vim.json.encode({ type = "error", message = tostring(err) }))
    f:close()
    vim.cmd("qall!")
  end
end

local function wait(ms)
  vim.defer_fn(resume, ms)
  coroutine.yield()
end

---@param req table
local function request(req)
  seq = seq + 1
  local path = ("%s/req-%03d.json"):format(dir, seq)
  -- Write then rename so the runner never reads a partial file.
  local f = assert(io.open(path .. ".tmp", "w"))
  f:write(vim.json.encode(req))
  f:close()
  assert(os.rename(path .. ".tmp", path))
  if req.type == "quit" then
    return
  end

  local ack = ("%s/ack-%03d"):format(dir, seq)
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(50, 50, function()
    waited = waited + 50
    if vim.uv.fs_stat(ack) or waited > ACK_TIMEOUT_MS then
      timer:close()
      vim.schedule(resume)
    end
  end)
  coroutine.yield()
  assert(vim.uv.fs_stat(ack), "runner did not answer request " .. seq)
end

---Where an image anchored at `lnum` should be, or nil when it is off screen.
---@param win integer
---@param lnum integer
---@param col? integer
---@param size? { cols: integer, rows: integer }
local function expected(win, lnum, col, size)
  size = size or { cols = IMG_COLS, rows = IMG_ROWS }
  local info = vim.fn.getwininfo(win)[1]
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local top
  if lnum == view.topline - 1 then
    -- Only the last `topfill` virt_lines of the anchor line are shown.
    top = info.winrow + view.topfill - size.rows
  else
    local row = vim.fn.screenpos(win, lnum, 1).row
    if row == 0 then
      return nil
    end
    top = row + 1
  end
  return {
    image = {
      row = top,
      col = info.wincol + info.textoff + (col or 0),
      rows = size.rows,
      cols = size.cols,
    },
    clip = {
      row = info.winrow,
      col = info.wincol + info.textoff,
      rows = info.height,
      cols = info.width - info.textoff,
    },
  }
end

---@param name string
---@param images table[]
local function capture(name, images)
  request({
    type = "capture",
    name = name,
    images = images,
    screen = { rows = vim.o.lines, cols = vim.o.columns },
  })
end

local function show(lnum, col, size, path)
  local handle, err = blit.show(path or fixture, {
    width = size and size.cols or IMG_COLS,
    height = size and size.rows or IMG_ROWS,
    lnum = lnum,
    col = col,
  })
  assert(handle, err)
  wait(SETTLE_MS)
  return handle
end

local function clear(handle)
  blit.clear(handle)
  wait(SETTLE_MS)
end

local function set_view(topline, topfill)
  -- Move the cursor too, or the next redraw scrolls back to it.
  vim.fn.winrestview({ topline = topline, topfill = topfill or 0, lnum = topline, col = 0 })
  wait(SETTLE_MS)
end

-- Resize the terminal window itself, wait for Neovim to see it, then wait
-- `settle_ms` (default SETTLE_MS * 2; 0 returns right away). Fails the run if
-- the size did not change, since later checks would prove nothing.
local function resize(dw, dh, settle_ms)
  local before = { vim.o.lines, vim.o.columns }
  local function changed()
    return before[1] ~= vim.o.lines or before[2] ~= vim.o.columns
  end
  request({ type = "resize", dw = dw, dh = dh })
  for _ = 1, 100 do
    if changed() then
      break
    end
    wait(20)
  end
  assert(changed(), "terminal size did not change after resizing its window")
  if settle_ms ~= 0 then
    wait(settle_ms or SETTLE_MS * 2)
  end
end

---Paint a marker block with its top-left at buffer (lnum, col) and return
---where it is on screen, in 1-based screen cells.
---@param win integer
---@param lnum integer
---@param col integer 0-based byte column
local function paint_marker(win, lnum, col)
  local buf = vim.api.nvim_win_get_buf(win)
  for row = lnum, lnum + MARKER_SIZE.rows - 1 do
    vim.api.nvim_buf_set_extmark(buf, marker_ns, row - 1, col, {
      end_col = col + MARKER_SIZE.cols,
      hl_group = MARKER_HL,
    })
  end
  local pos = vim.fn.screenpos(win, lnum, col + 1)
  return { row = pos.row, col = pos.col, rows = MARKER_SIZE.rows, cols = MARKER_SIZE.cols }
end

-- Measure the cell grid from two marker blocks near the top-left and
-- bottom-right corners; their outer edges span most of the screen, so rounding
-- error stays small. The markers share a color with the fixture, so they are
-- painted in a new tab, where blit hides every image (#16) without destroying
-- the handles. They stay one cell clear of the screen edges, which some
-- terminals extend into the window padding (e.g. Ghostty's
-- window-padding-color = extend), and of the cursor at line 1, column 1.
---@param name string
local function calibrate(name)
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  local win = vim.api.nvim_get_current_win()
  local info = vim.fn.getwininfo(win)[1]
  local blank = (" "):rep(info.width)
  local lines = {}
  for i = 1, info.height do
    lines[i] = blank
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local markers = {
    paint_marker(win, 2, 1),
    paint_marker(win, info.height - MARKER_SIZE.rows, info.width - MARKER_SIZE.cols - 1),
  }
  wait(SETTLE_MS)
  request({
    type = "calibrate",
    name = name,
    markers = markers,
    screen = { rows = vim.o.lines, cols = vim.o.columns },
  })
  vim.cmd("tabclose")
  -- tabclose moves to a neighbor, which need not be the tab we came from.
  vim.api.nvim_set_current_tabpage(tab)
  wait(SETTLE_MS)
end

local function open_scratch()
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "hide"
  local lines = {}
  for i = 1, 200 do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  return vim.api.nvim_get_current_buf()
end

---@param name string
---@param ok boolean
---@param detail? string why it failed
local function result(name, ok, detail)
  local line = (ok and "PASS " or "FAIL ") .. name
  if not ok and detail then
    line = line .. ": " .. detail
  end
  request({ type = "result", line = line })
end

-- Wrap renderer._write_fn so checks can tell what blit sent, e.g. whether an
-- image was transmitted again (a=T/a=t) or only placed (a=p).
local function record_writes()
  local write = renderer._write_fn
  renderer._write_fn = function(sequences)
    writes[#writes + 1] = table.concat(sequences)
    return write(sequences)
  end
end

---Number of recorded write batches after `since` that send the action.
---@param since integer index into `writes`
---@param action "transmit"|"place"
local function count_writes(since, action)
  local patterns = action == "transmit" and { "\27_Ga=T,", "\27_Ga=t," } or { "\27_Ga=p," }
  local n = 0
  for i = since + 1, #writes do
    for _, pattern in ipairs(patterns) do
      if writes[i]:find(pattern, 1, true) then
        n = n + 1
        break
      end
    end
  end
  return n
end

---@param from string
---@param to string
---@param edit? fun(data: string): string
local function copy_file(from, to, edit)
  local f = assert(io.open(from, "rb"))
  local data = f:read("a")
  f:close()
  f = assert(io.open(to .. ".tmp", "wb"))
  f:write(edit and edit(data) or data)
  f:close()
  assert(os.rename(to .. ".tmp", to))
end

-- Keeps the PNG signature and IHDR valid, so blit sends it, but breaks the
-- zlib header of the image data, so the terminal rejects it.
local function break_image_data(data)
  local start = assert(data:find("IDAT", 1, true), "fixture has no IDAT chunk") + 4
  return data:sub(1, start - 1) .. "\0\0" .. data:sub(start + 2)
end

local function check_health()
  vim.cmd("checkhealth blit")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.api.nvim_buf_delete(0, { force = true })
  local supported = text:find("blit is supported in this environment", 1, true)
  local error_line = text:match("[^\n]*ERROR[^\n]*")
  if supported and not error_line then
    request({ type = "result", line = "PASS checkhealth" })
  elseif not supported then
    request({ type = "result", line = "FAIL checkhealth: does not report supported" })
  else
    request({ type = "result", line = "FAIL checkhealth: " .. vim.trim(error_line) })
  end
end

local function run()
  local want = os.getenv("BLIT_E2E_TERMINAL")
  local caps = terminal.detect()
  assert(caps.supported, "blit is not supported here: " .. tostring(caps.reason))
  assert(caps.terminal == want, ("detected %s, expected %s"):format(caps.terminal, want))
  record_writes()

  -- Let the runner find the window (and float it under a tiling WM) before
  -- any geometry is measured.
  wait(300)
  request({ type = "ready" })
  wait(SETTLE_MS)

  local buf = open_scratch()
  local win = vim.api.nvim_get_current_win()
  calibrate("calibrate")

  local handle = show(2)
  capture("show", { expected(win, 2) })
  clear(handle)

  handle = show(2, 8)
  capture("col offset (#9)", { expected(win, 2, 8) })
  clear(handle)

  handle = show(2)
  set_view(3, 3)
  capture("crop at top edge (#28)", { expected(win, 2) })
  set_view(1)
  capture("uncrop after scrolling back", { expected(win, 2) })
  clear(handle)

  local bottom_lnum = vim.api.nvim_win_get_height(win) - 3
  handle = show(bottom_lnum)
  capture("crop at bottom edge (#23)", { expected(win, bottom_lnum) })
  clear(handle)

  local right_col = vim.fn.getwininfo(win)[1].width - IMG_COLS / 2
  handle = show(2, right_col)
  capture("crop at right edge (#9)", { expected(win, 2, right_col) })
  clear(handle)

  handle = show(2)
  blit.clear(handle)
  wait(SETTLE_MS * 2)
  capture("clear without redraw (#27)", {})

  local first = show(2)
  local second = show(20)
  capture("same image twice (#10)", { expected(win, 2), expected(win, 20) })
  clear(first)
  capture("clear one of two (#10)", { expected(win, 20) })
  clear(second)

  local lower = show(12)
  local upper = show(4)
  capture("image above moves the one below (#18)", { expected(win, 12), expected(win, 4) })
  clear(upper)
  clear(lower)

  local box = { cols = 40, rows = 4 }
  handle = show(2, 0, box)
  capture("fills a box of another aspect ratio", { expected(win, 2, 0, box) })
  clear(handle)

  -- The fixture is 80x120 px, so a 40x4 box is bounded by its height (#76).
  handle = assert(blit.show(fixture, { max_width = 40, max_height = 4, lnum = 2 }))
  wait(SETTLE_MS)
  local fitted = { cols = handle.geometry.cols, rows = handle.geometry.rows }
  result("max_width/max_height keep the aspect ratio (#76)", fitted.rows == 4 and fitted.cols < 40)
  capture("fits inside max_width/max_height (#76)", { expected(win, 2, 0, fitted) })
  clear(handle)

  handle = show(2)
  local mark = #writes
  set_view(60)
  set_view(1)
  capture("back in view after scrolling out", { expected(win, 2) })
  result("no retransmit when scrolled back into view", count_writes(mark, "transmit") == 0)
  clear(handle)
  mark = #writes
  handle = show(2)
  result("re-show after clear() reuses the cached image", count_writes(mark, "transmit") == 0)
  clear(handle)

  copy_file(fixture, swap)
  clear(show(2, nil, nil, swap))
  copy_file(variant, swap)
  handle = show(2, nil, nil, swap)
  local overwritten = expected(win, 2)
  overwritten.variant = VARIANT
  capture("overwritten file shows the new image (#11)", { overwritten })
  clear(handle)

  handle = show(2)
  vim.cmd("vsplit")
  local left = vim.api.nvim_get_current_win()
  wait(SETTLE_MS)
  capture("follows its window after :vsplit", { expected(win, 2) })
  mark = #writes
  for _ = 1, 5 do
    vim.cmd("vertical resize -2")
    wait(2)
  end
  wait(SETTLE_MS)
  capture("follows its window after :vertical resize", { expected(win, 2) })
  local passes = count_writes(mark, "place")
  result("one redraw pass per resize burst", passes == 1, passes .. " passes")
  vim.api.nvim_win_close(left, true)
  wait(SETTLE_MS)
  clear(handle)

  handle = show(2)
  vim.cmd("tabnew")
  wait(SETTLE_MS)
  capture("hidden in a new tab (#16)", {})
  vim.cmd("tabprevious")
  wait(SETTLE_MS)
  capture("restored on tab return (#16)", { expected(win, 2) })

  open_scratch()
  wait(SETTLE_MS)
  capture("removed on buffer switch", {})
  vim.api.nvim_win_set_buf(win, buf)
  blit.clear_all()
  wait(SETTLE_MS)

  vim.cmd("split")
  local split_win = vim.api.nvim_get_current_win()
  show(2)
  vim.api.nvim_win_close(split_win, true)
  wait(SETTLE_MS)
  capture("removed on window close", {})

  -- Resizing the terminal window itself (#34), then showing after a resize (#24).
  -- The grid is measured again after every resize; run.sh holds back checking
  -- a capture taken before that until it is.
  handle = show(2)
  resize(-80, -80)
  capture("visible after window resize (#34)", { expected(win, 2) })
  calibrate("calibrate after resize")
  resize(80, 80)
  capture("visible after second resize (#34)", { expected(win, 2) })
  calibrate("calibrate after second resize")
  clear(handle)
  resize(-80, -80)
  calibrate("calibrate after third resize")
  handle = show(2)
  capture("re-show after window resize (#24)", { expected(win, 2) })

  -- A second show() right after a resize, while the first image is still
  -- visible, must not place the id Ghostty dropped (#61).
  resize(80, 80, 0)
  local again = assert(blit.show(fixture, { width = IMG_COLS, height = IMG_ROWS, lnum = 20 }))
  wait(SETTLE_MS * 2)
  capture("show right after window resize (#61)", { expected(win, 2), expected(win, 20) })
  clear(again)
  calibrate("calibrate after fourth resize")

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local stray = vim.fn.mode() ~= "n"
    or #lines ~= 200
    or lines[1] ~= "line 1"
    or lines[200] ~= "line 200"
  result(
    "no stray input after use",
    not stray,
    "mode " .. vim.fn.mode() .. ", " .. #lines .. " lines"
  )

  check_health()

  -- After check_health(), which fails on any rejected image.
  blit.clear_all()
  copy_file(fixture, corrupt, break_image_data)
  handle = show(2, nil, nil, corrupt)
  capture("corrupt PNG shows nothing", {})
  local listed = false
  for _, response_error in ipairs(renderer.response_errors()) do
    listed = listed or response_error.path == corrupt
  end
  -- WezTerm sends no error response for bad image data (docs/spec/kitty-graphics.md).
  local want_listed = want ~= "wezterm"
  result(
    "corrupt PNG " .. (want_listed and "is" or "is not") .. " listed as rejected",
    listed == want_listed,
    listed and "listed" or "not listed"
  )
  clear(handle)

  request({
    type = "quit",
    name = "nothing left after :qa",
    images = {},
    screen = { rows = vim.o.lines, cols = vim.o.columns },
  })
  vim.cmd("qall!")
end

vim.o.title = true
vim.o.titlestring = "blit-e2e"
vim.o.titleold = "blit-e2e"
vim.o.laststatus = 2
vim.o.number = false
vim.opt.shortmess:append("I")
-- The marker color must reach the terminal as 24-bit RGB, not a palette index.
vim.o.termguicolors = true
vim.api.nvim_set_hl(0, MARKER_HL, { bg = MARKER_COLOR })

runner = coroutine.create(run)
vim.schedule(resume)
