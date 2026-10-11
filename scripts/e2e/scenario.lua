-- Neovim side of the e2e run. Started by scripts/e2e/run.sh inside the
-- terminal under test; not meant to be run by hand.
--
-- Each step talks to the runner through files in $BLIT_E2E_DIR:
--   req-NNN.json  written here ({ type = "ready" | "capture" | "resize" | "result" | "quit" | "error" })
--   ack-NNN       written by the runner once the request is handled
--
-- A "capture" request carries where each image should be on screen, in
-- 1-based screen cells. run.sh takes a screenshot and check.py compares it.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

local blit = require("blit")
local terminal = require("blit.terminal")

local dir = assert(os.getenv("BLIT_E2E_DIR"), "BLIT_E2E_DIR is not set")
local fixture = dir .. "/fixture.png"

local IMG_COLS = 8
local IMG_ROWS = 6
-- Cell size is measured from two copies at the top-left and far right of
-- the window, so rounding error does not add up across the screen.
local CALIBRATION_COLS = 24
local CALIBRATION_ROWS = 12
-- Long enough for the debounce, Ghostty's resize settle timer, and a repaint.
local SETTLE_MS = 400
local ACK_TIMEOUT_MS = 30000

local seq = 0
local runner

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
---@param calibrate? boolean
local function capture(name, images, calibrate)
  request({
    type = "capture",
    name = name,
    images = images,
    calibrate = calibrate,
    screen = { rows = vim.o.lines, cols = vim.o.columns },
  })
end

local function show(lnum, col, size)
  local handle, err = blit.show(fixture, {
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

-- Resize the terminal window itself and wait for Neovim to see it. Fails the
-- run if the size did not change, since later checks would prove nothing.
local function resize(dw, dh)
  local before = { vim.o.lines, vim.o.columns }
  request({ type = "resize", dw = dw, dh = dh })
  wait(SETTLE_MS * 2)
  assert(
    before[1] ~= vim.o.lines or before[2] ~= vim.o.columns,
    "terminal size did not change after resizing its window"
  )
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

  -- Let the runner find the window (and float it under a tiling WM) before
  -- any geometry is measured.
  wait(300)
  request({ type = "ready" })
  wait(SETTLE_MS)

  local buf = open_scratch()
  local win = vim.api.nvim_get_current_win()

  local size = { cols = CALIBRATION_COLS, rows = CALIBRATION_ROWS }
  local right_edge = vim.fn.getwininfo(win)[1].width - CALIBRATION_COLS
  local top_left = show(2, 0, size)
  local bottom_right = show(3, right_edge, size)
  capture("calibrate", { expected(win, 2, 0, size), expected(win, 3, right_edge, size) }, true)
  clear(top_left)
  clear(bottom_right)

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
  handle = show(2)
  resize(-80, -80)
  capture("visible after window resize (#34)", { expected(win, 2) })
  resize(80, 80)
  capture("visible after second resize (#34)", { expected(win, 2) })
  clear(handle)
  resize(-80, -80)
  handle = show(2)
  capture("re-show after window resize (#24)", { expected(win, 2) })

  check_health()

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

runner = coroutine.create(run)
vim.schedule(resume)
