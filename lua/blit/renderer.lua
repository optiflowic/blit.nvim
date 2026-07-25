-- Placement layer. Maps a buffer/window position to an on-screen kitty
-- graphics placement: extmark virtual-line reservation, screen coordinate
-- conversion, transmission caching, and lifecycle autocmds. See
-- docs/spec/renderer-placement.md — implementation here must match that
-- memo; if reality diverges, fix the memo in the same change.
--
-- This module knows nothing about escape sequence syntax; it only calls
-- blit.terminal's pure builders and its write() transport. It owns every
-- autocmd and extmark blit creates.

local terminal = require("blit.terminal")
local config = require("blit.config")
local png = require("blit.png")

local M = {}

local AUGROUP = "blit"
local NAMESPACE = "blit"

---@class blit.Geometry
---@field lnum integer 1-indexed anchor buffer line
---@field col integer 0-indexed anchor byte column; currently unused for
---placement (virt_lines always render at the window's text-area left edge,
---independent of the extmark's column) — reserved for future use
---@field cols integer target placement width in cell columns
---@field rows integer target placement height in cell rows

---@class blit.Handle
---@field id integer kitty image id (blit's reserved range)
---@field buf integer
---@field win integer
---@field extmark_id integer
---@field path string
---@field cache_key string
---@field geometry blit.Geometry
---@field z_index? integer
---@field visible boolean
---@field native_width integer PNG native pixel width, from png.read_ihdr; used only for crop math, never for auto-sizing
---@field native_height integer PNG native pixel height, from png.read_ihdr

M._handles = {}

-- Overridable seam for tests: production code always goes through
-- terminal.write(); tests inject a capturing function so they never touch a
-- real tty, mirroring terminal.lua's own M._writer_factory seam.
M._write_fn = function(sequences)
  return terminal.write(sequences)
end

-- Overridable seam for tests: production code always goes through
-- terminal.detect(), which correctly reports gui_embed under a headless
-- test runner (no real ttyout). Tests inject a stub so the geometry/cache/
-- lifecycle logic below is exercisable without a real supported terminal.
M._detect_fn = terminal.detect

-- Overridable seam for tests: production code always forces a synchronous
-- screen redraw so a just-added virt_lines reservation has actually been
-- flushed to the real terminal before positioning a placement against it
-- (issue #19) — Neovim's own redraw-to-tty output is scheduled
-- asynchronously and can race blit's direct-tty write otherwise.
M._redraw_fn = function()
  vim.cmd("redraw")
end

-- Image id allocation ---------------------------------------------------------
-- Pure logic over terminal.lua's reserved range. Ids are handed out
-- sequentially and only returned to the free pool by destroy_handle's
-- free_data path (VimLeavePre, clear/clear_all's full teardown) or _reset().
-- See docs/spec/renderer-placement.md's "Transmission cache" section.

local next_id = terminal.ID_RANGE_START
local used_ids = {}

---@return integer? id
---@return string? err
local function alloc_id()
  local range_size = terminal.ID_RANGE_END - terminal.ID_RANGE_START + 1
  for _ = 1, range_size do
    local id = next_id
    next_id = next_id + 1
    if next_id > terminal.ID_RANGE_END then
      next_id = terminal.ID_RANGE_START
    end
    if not used_ids[id] then
      used_ids[id] = true
      return id
    end
  end
  return nil, "blit.renderer: no free image ids left in reserved range"
end

---@param id integer
local function free_id(id)
  used_ids[id] = nil
end

-- Transmission cache ----------------------------------------------------------

---@type table<string, { id: integer, active: boolean, lines: integer, columns: integer, native_width: integer, native_height: integer }[]>
local cache = {}

---@param path string
---@param mtime { sec: integer, nsec: integer }
---@return string
local function cache_key(path, mtime)
  return path .. ":" .. mtime.sec .. "." .. mtime.nsec
end
M.cache_key = cache_key

-- Ghostty discards previously-transmitted image data behind an id across a
-- real terminal window resize, with no error response to detect it by (q=2
-- suppresses all responses — see docs/spec/kitty-graphics.md's "Response
-- handling"): reusing such an id for a placement-only reuse (`a=p`) then
-- silently renders nothing (issue #24). Each cache entry therefore records
-- the Neovim grid size (`vim.o.lines`/`vim.o.columns`, which tracks the
-- real terminal's size, not just a per-window size) at transmit time;
-- acquire_idle_entry rejects (and frees) an idle entry recorded against a
-- stale size on Ghostty, forcing a fresh transmit instead of trusting dead
-- data. This is a lazy, reuse-time check rather than a `VimResized`
-- listener specifically to avoid needing a persistent autocmd outside the
-- handle-gated augroup — see docs/spec/renderer-placement.md's
-- Transmission cache section for why and its accepted false-negative case
-- (a resize that lands back on the exact original size in between is
-- indistinguishable from no resize at all).
--
-- The same size-mismatch signal also drives redraw_all's still-visible-
-- handle path below (issue #34): a handle that stays active/displayed
-- across a Ghostty resize is not touched by acquire_idle_entry at all (it's
-- never idle), so without this it stayed permanently blank once its data
-- was discarded — see "Redraw" below and
-- docs/spec/renderer-placement.md's Transmission cache section.
--
-- This one fact — which terminal actually has this quirk — is centralized
-- here rather than compared inline at each call site, so acquire_idle_entry,
-- redraw_all's stale check, and its resize-race redraw guard all agree on
-- the same definition as more terminals/quirks are added over time.
---@param terminal_name "kitty"|"wezterm"|"ghostty"|nil
---@return boolean
local function discards_pixels_on_resize(terminal_name)
  return terminal_name == "ghostty"
end

-- Destroy-path delete retry queue --------------------------------------------
-- destroy_handle's a=d is as susceptible to WezTerm's scroll-driven
-- rendering lag as redraw_all's hide (issue #23), but a destroyed handle
-- leaves M._handles for good, so there is no later redraw pass left to ever
-- retry it (issue #27) — unlike a still-tracked invisible handle, which
-- gets a fresh retry on every subsequent WinScrolled/WinResized pass. Since
-- destroy can happen with no further such event ever firing (clear_all()
-- with no follow-up scroll), the retry has to be self-scheduled rather than
-- riding on redraw_all's normal event-driven cadence. Bounded (not
-- indefinite like the still-tracked case) so a terminal that never honors
-- the delete can't keep blit's debounce timer alive forever, violating
-- AGENTS.md's "fully quiescent idle" rule.

local DESTROY_DELETE_RETRIES = 3

---@type { id: integer, retries: integer }[]
local pending_deletes = {}

---@param id integer
local function cancel_pending_delete(id)
  for i, pending in ipairs(pending_deletes) do
    if pending.id == id then
      table.remove(pending_deletes, i)
      return
    end
  end
end

---@param key string
---@param terminal_name "kitty"|"wezterm"|"ghostty"|nil
---@return { id: integer, active: boolean, lines: integer, columns: integer, native_width: integer, native_height: integer }?
local function acquire_idle_entry(key, terminal_name)
  local entries = cache[key]
  if not entries then
    return nil
  end
  local i = 1
  while i <= #entries do
    local entry = entries[i]
    if entry.active then
      i = i + 1
    elseif
      discards_pixels_on_resize(terminal_name)
      and (entry.lines ~= vim.o.lines or entry.columns ~= vim.o.columns)
    then
      free_id(entry.id)
      table.remove(entries, i)
    else
      entry.active = true
      -- The id may still have a bounded delete retry outstanding from a
      -- prior destroy (see "Destroy-path delete retry queue" above); this
      -- reuse legitimately reclaims it, so a late retry must not delete the
      -- placement being made here.
      cancel_pending_delete(entry.id)
      return entry
    end
  end
  return nil
end

---@param key string
---@param id integer
---@param native_width integer
---@param native_height integer
local function register_cache_entry(key, id, native_width, native_height)
  cache[key] = cache[key] or {}
  table.insert(cache[key], {
    id = id,
    active = true,
    lines = vim.o.lines,
    columns = vim.o.columns,
    native_width = native_width,
    native_height = native_height,
  })
end

---@param key string
---@param id integer
---@return { id: integer, active: boolean, lines: integer, columns: integer, native_width: integer, native_height: integer }?
local function find_cache_entry(key, id)
  local entries = cache[key]
  if not entries then
    return nil
  end
  for _, entry in ipairs(entries) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

---@param key string
---@param id integer
local function mark_cache_entry_idle(key, id)
  local entries = cache[key]
  if not entries then
    return
  end
  for _, entry in ipairs(entries) do
    if entry.id == id then
      entry.active = false
      return
    end
  end
end

---@param key string
---@param id integer
local function drop_cache_entry(key, id)
  local entries = cache[key]
  if not entries then
    return
  end
  for i, entry in ipairs(entries) do
    if entry.id == id then
      table.remove(entries, i)
      return
    end
  end
end

-- Geometry ----------------------------------------------------------------
-- Pure integer math, unit-tested directly. A placement is hidden only when
-- it has no overlap at all with its window's bounds; a partial overlap
-- shows a cropped slice instead. See docs/spec/renderer-placement.md's
-- "Visibility policy".

-- compute_clip is the single source of truth for how much of a row/col span
-- falls outside a window's bounds on each end; fully_within is kept as a
-- thin wrapper (rather than removed) so every existing all-or-nothing test
-- keeps passing unchanged. See docs/spec/renderer-placement.md's Visibility
-- policy section.
---@param anchor integer
---@param span integer
---@param bound_start integer
---@param bound_end integer
---@return integer clip_low cells clipped from the low (top/left) end
---@return integer clip_high cells clipped from the high (bottom/right) end
---@return integer visible_span 0 if nothing overlaps the bounds at all
local function compute_clip(anchor, span, bound_start, bound_end)
  if anchor <= 0 then
    return 0, 0, 0
  end
  local span_end = anchor + span - 1
  local clip_low = math.max(0, bound_start - anchor)
  local clip_high = math.max(0, span_end - bound_end)
  local visible_span = span - clip_low - clip_high
  if visible_span <= 0 then
    return clip_low, clip_high, 0
  end
  return clip_low, clip_high, visible_span
end
M.compute_clip = compute_clip

---@param anchor integer
---@param span integer
---@param bound_start integer
---@param bound_end integer
---@return boolean
local function fully_within(anchor, span, bound_start, bound_end)
  local clip_low, clip_high, visible_span = compute_clip(anchor, span, bound_start, bound_end)
  return clip_low == 0 and clip_high == 0 and visible_span == span
end
M.fully_within = fully_within

-- Converts a cell-based clip amount into a proportional pixel offset/size
-- against the image's native pixel dimensions, for kitty's placement
-- source-rectangle keys (x/y or w/h — see docs/spec/kitty-graphics.md's
-- "Source-rectangle cropping" section). Proof size_px >= 1 whenever
-- visible_span > 0: clip_low + clip_high < total_cells (strict, since
-- visible_span = total_cells - clip_low - clip_high > 0), so
-- offset_px + high_px <= floor((clip_low+clip_high) * native_px /
-- total_cells) < native_px (floor(a)+floor(b) <= floor(a+b), and the ratio
-- is strictly < 1) — an integer strictly less than native_px is at most
-- native_px - 1, so size_px = native_px - offset_px - high_px >= 1.
---@param clip_low_cells integer
---@param clip_high_cells integer
---@param total_cells integer
---@param native_px integer
---@return integer offset_px
---@return integer size_px
local function pixel_crop(clip_low_cells, clip_high_cells, total_cells, native_px)
  local offset_px = math.floor(clip_low_cells * native_px / total_cells)
  local high_px = math.floor(clip_high_cells * native_px / total_cells)
  return offset_px, native_px - offset_px - high_px
end
M.pixel_crop = pixel_crop

---@param win integer
---@return { top: integer, bottom: integer, left: integer, right: integer }
local function window_bounds(win)
  local pos = vim.api.nvim_win_get_position(win)
  local top = pos[1] + 1
  local left = pos[2] + 1
  return {
    top = top,
    left = left,
    bottom = top + vim.api.nvim_win_get_height(win) - 1,
    right = left + vim.api.nvim_win_get_width(win) - 1,
  }
end

---@class blit.PlacementResult
---@field screen_row integer shifted from the raw anchor row when top-clipped
---@field screen_col integer shifted from the raw anchor col when left-clipped
---@field cols integer target cell width; shrinks to the visible column span when clipped
---@field rows integer target cell height; shrinks to the visible row span when clipped
---@field crop_x? integer present only when column-clipped from the left
---@field crop_y? integer present only when row-clipped from the top
---@field crop_w? integer present only when column-clipped from either side
---@field crop_h? integer present only when row-clipped from either side

-- `winsaveview().topfill` (used in compute_placement's scrolled-off-anchor
-- fallback below) counts filler/virtual lines above topline for the whole
-- window, not per-extmark — if another handle's virt_lines block is also
-- anchored at this handle's own lnum, topfill would reflect their combined
-- row counts and the fallback's crop math could not be trusted.
---@param handle blit.Handle
---@return boolean
local function has_sibling_at_same_lnum(handle)
  for _, other in ipairs(M._handles) do
    if
      other ~= handle
      and other.buf == handle.buf
      and other.geometry.lnum == handle.geometry.lnum
    then
      return true
    end
  end
  return false
end

-- Under 'wrap', the anchor line can occupy more than one screen row, and
-- virt_lines render immediately below its LAST wrapped row, not its first
-- (issue #7). screenpos() already maps a buffer column to the correct
-- wrapped screen row — including 'breakindent'/'showbreak' effects — so
-- querying it at the line's own last byte column (instead of column 1)
-- yields that last row directly, with no wrap-width math of our own needed.
-- Returns 0 if that last column is not currently rendered at all (its wrap
-- tail has scrolled past the window's bottom edge, even though column 1 of
-- the same line is still visible there).
---@param win integer
---@param buf integer
---@param lnum integer
---@return integer row 0 if the line's last column is not rendered
local function anchor_last_row(win, buf, lnum)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local last_col = math.max(1, #line)
  local ok, pos = pcall(vim.fn.screenpos, win, lnum, last_col)
  if not ok or pos.row <= 0 then
    return 0
  end
  return pos.row
end

---@param handle blit.Handle
---@return blit.PlacementResult?
local function compute_placement(handle)
  if not vim.api.nvim_win_is_valid(handle.win) or not vim.api.nvim_buf_is_valid(handle.buf) then
    return nil
  end
  if vim.api.nvim_win_get_buf(handle.win) ~= handle.buf then
    return nil
  end
  -- screenpos() does not itself account for tab visibility: it keeps
  -- returning a window's real screen row/col even when that window's tab
  -- is not the currently active tabpage (verified) — so visibility must be
  -- checked explicitly here (issue #16).
  if vim.api.nvim_win_get_tabpage(handle.win) ~= vim.api.nvim_get_current_tabpage() then
    return nil
  end

  -- virt_lines always render starting at the window's text-area left edge
  -- (the same screen column as byte column 1 of any line), independent of
  -- the extmark's own column — nvim_buf_set_extmark below anchors it at
  -- column 0 regardless of handle.geometry.col. Column 1 is queried here
  -- to match that, not handle.geometry.col (currently unused for
  -- placement; see the Geometry class doc comment).
  local ok, pos = pcall(vim.fn.screenpos, handle.win, handle.geometry.lnum, 1)
  if not ok then
    return nil
  end

  local bounds = window_bounds(handle.win)
  local final_row, screen_col, row_lo, row_hi, vis_rows

  if pos.row > 0 then
    -- virt_lines render immediately below the anchor line's own LAST
    -- rendered screen row (see anchor_last_row's comment above). If that
    -- last row is itself off-screen (the line's wrap tail ran past the
    -- window's bottom edge, even though its first row at pos.row is still
    -- visible), the reserved block is entirely below the window too —
    -- bounds.bottom + 1 makes compute_clip below report zero visible rows.
    local last_row = anchor_last_row(handle.win, handle.buf, handle.geometry.lnum)
    local screen_row = (last_row > 0 and last_row or bounds.bottom) + 1
    screen_col = pos.col
    row_lo, row_hi, vis_rows =
      compute_clip(screen_row, handle.geometry.rows, bounds.top, bounds.bottom)
    final_row = screen_row + row_lo
  else
    -- The anchor line itself has scrolled off (screenpos reports row 0),
    -- but Neovim's virt_lines rendering treats the anchor line plus its
    -- reserved rows as one scrollable block (see docs/spec/renderer-
    -- placement.md's Visibility policy): the tail of that block can still
    -- be showing at the window's own top edge. `winsaveview().topfill`
    -- reports exactly how many reserved rows remain visible, but only
    -- means anything for THIS handle's block when the window's topline has
    -- landed exactly on the line right after the anchor (confirmed
    -- empirically: topfill counts down from geometry.rows to 0 across a
    -- gradual scroll through the block, then topline advances past it and
    -- topfill resets to 0) — any other topline means the block is either
    -- not reached yet (impossible here, since pos.row would be > 0) or
    -- already scrolled fully past.
    local view = vim.api.nvim_win_call(handle.win, vim.fn.winsaveview)
    if view.topline ~= handle.geometry.lnum + 1 or view.topfill <= 0 then
      return nil
    end
    if has_sibling_at_same_lnum(handle) then
      return nil
    end
    -- The line right after the anchor is guaranteed visible here (topfill
    -- counts rows *before* it), so its screen column is a valid stand-in
    -- for the invisible anchor line's own column (both render virt_lines
    -- at the same window text-area left edge).
    local ok2, pos2 = pcall(vim.fn.screenpos, handle.win, view.topline, 1)
    if not ok2 or pos2.row <= 0 then
      return nil
    end
    screen_col = pos2.col
    row_lo = math.max(0, handle.geometry.rows - view.topfill)
    local raw_visible = handle.geometry.rows - row_lo
    _, row_hi, vis_rows = compute_clip(bounds.top, raw_visible, bounds.top, bounds.bottom)
    final_row = bounds.top
  end

  if vis_rows <= 0 then
    return nil
  end
  local col_lo, col_hi, vis_cols =
    compute_clip(screen_col, handle.geometry.cols, bounds.left, bounds.right)
  if vis_cols <= 0 then
    return nil
  end

  ---@type blit.PlacementResult
  local placement = {
    screen_row = final_row,
    screen_col = screen_col + col_lo,
    cols = vis_cols,
    rows = vis_rows,
  }
  if row_lo > 0 or row_hi > 0 then
    placement.crop_y, placement.crop_h =
      pixel_crop(row_lo, row_hi, handle.geometry.rows, handle.native_height)
  end
  if col_lo > 0 or col_hi > 0 then
    placement.crop_x, placement.crop_w =
      pixel_crop(col_lo, col_hi, handle.geometry.cols, handle.native_width)
  end
  return placement
end

-- Namespace / extmarks ---------------------------------------------------------

local ns_id = nil

---@return integer
local function ensure_namespace()
  ns_id = ns_id or vim.api.nvim_create_namespace(NAMESPACE)
  return ns_id
end

---@param height integer
---@return table[]
local function build_virt_lines(height)
  local lines = {}
  for _ = 1, height do
    lines[#lines + 1] = { { "", "Normal" } }
  end
  return lines
end

-- File reading --------------------------------------------------------------

---@param path string
---@return string? bytes
---@return string? err
local function read_file(path)
  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "blit: cannot open " .. path .. ": " .. tostring(open_err)
  end
  local bytes = f:read("*a")
  f:close()
  if not bytes then
    return nil, "blit: failed to read " .. path
  end
  return bytes
end

-- Placement / hide --------------------------------------------------------

---@param handle blit.Handle
---@param placement blit.PlacementResult
---@return blit.terminal.PlacementOpts
local function placement_opts(handle, placement)
  return {
    columns = placement.cols,
    rows = placement.rows,
    z_index = handle.z_index,
    no_move_cursor = true,
    crop_x = placement.crop_x,
    crop_y = placement.crop_y,
    crop_w = placement.crop_w,
    crop_h = placement.crop_h,
  }
end

---@param handle blit.Handle
---@param placement blit.PlacementResult
---@return boolean ok
---@return string? err
local function place_existing(handle, placement)
  local sequences = {
    terminal.build_save_cursor(),
    terminal.build_move_cursor(placement.screen_row, placement.screen_col),
    terminal.build_placement(handle.id, placement_opts(handle, placement)),
    terminal.build_restore_cursor(),
  }
  local ok, err = M._write_fn(sequences)
  handle.visible = ok and true or false
  return ok, err
end

---@param handle blit.Handle
local function hide_existing(handle)
  M._write_fn({ terminal.build_delete(handle.id) })
  handle.visible = false
end

-- On Ghostty, a still-visible handle's transmitted data can have been
-- silently discarded by the same real terminal resize acquire_idle_entry
-- guards against for idle entries (issue #24/#34) — see the "Transmission
-- cache" comment above. There is no response to detect this by, so the
-- only signal available is the same one: the handle's cache entry was
-- recorded against a `vim.o.lines`/`vim.o.columns` that no longer matches.
---@param handle blit.Handle
---@param terminal_name "kitty"|"wezterm"|"ghostty"|nil
---@return boolean
local function ghostty_entry_stale(handle, terminal_name)
  if not discards_pixels_on_resize(terminal_name) then
    return false
  end
  local entry = find_cache_entry(handle.cache_key, handle.id)
  if not entry then
    return false
  end
  return entry.lines ~= vim.o.lines or entry.columns ~= vim.o.columns
end

-- Re-transmits a still-visible handle's pixel data under a *fresh* id and
-- updates the handle/cache to point at it, freeing the old, now-dead one —
-- confirmed via manual testing on a real Ghostty resize (issue #34) that
-- simply re-`a=T`-ing under the SAME id Ghostty already discarded does NOT
-- bring the placement back, even though the write itself reports success
-- (`q=2` suppresses all responses, so blit has no way to detect this other
-- than the empirical result). This mirrors `acquire_idle_entry`'s existing
-- Ghostty eviction above exactly: that path never reuses a stale id either —
-- it frees it and lets a fresh `alloc_id()` hand out a new one on the next
-- transmit. This is the one place outside `M.show()` that transmits rather
-- than reusing `a=p` — see AGENTS.md's performance rule on reuse-over-
-- retransmit for why that's normally forbidden and the narrow, Ghostty-only
-- exception carved out here.
---@param handle blit.Handle
---@param placement blit.PlacementResult
---@return boolean ok
local function retransmit_and_place(handle, placement)
  local bytes = read_file(handle.path)
  if not bytes then
    hide_existing(handle)
    return false
  end

  local new_id = alloc_id()
  if not new_id then
    hide_existing(handle)
    return false
  end

  local old_id = handle.id
  local sequences = {
    terminal.build_delete(old_id, { free_data = true }),
    terminal.build_save_cursor(),
    terminal.build_move_cursor(placement.screen_row, placement.screen_col),
  }
  vim.list_extend(
    sequences,
    terminal.build_transmit(
      bytes,
      { id = new_id, action = "T", placement = placement_opts(handle, placement) }
    )
  )
  table.insert(sequences, terminal.build_restore_cursor())

  local ok = M._write_fn(sequences)
  if ok then
    handle.id = new_id
    drop_cache_entry(handle.cache_key, old_id)
    free_id(old_id)
    register_cache_entry(handle.cache_key, new_id, handle.native_width, handle.native_height)
  else
    free_id(new_id)
  end
  handle.visible = ok and true or false
  return ok
end

-- Ghostty resize settle timer -------------------------------------------------
-- A real OS-window drag resize fires one `WinResized` per distinct cell-grid
-- size it passes through, not just once at the final size — confirmed via
-- manual testing (issue #34) that even a single, quick drag gesture crosses
-- several such sizes (observed: 6 within under a second). Retransmitting
-- (`a=T`, full base64 payload + a fresh id swap) on every one of those, back
-- to back, was observed to make Ghostty's own recovery unreliable — the
-- image came back on some redraw passes and not others, seemingly a race in
-- Ghostty's own rendering pipeline under rapid successive placement commands
-- for the same region rather than anything blit's escape-sequence content
-- gets wrong. Repositioning/hiding (`a=p`/`a=d`) every pass during the
-- drag is still cheap and stays on the normal per-pass debounce above; only
-- the expensive retransmit is pushed onto its own longer, separately-reset
-- timer so it fires (at most) once the resize has actually stopped for
-- `M._ghostty_settle_ms`, rather than once per intermediate size. 100ms was
-- confirmed via repeated manual testing on a real Ghostty window to be long
-- enough to avoid the back-to-back-retransmit instability above while still
-- feeling responsive once the drag stops.
local ghostty_retransmit_timer = nil
M._ghostty_settle_ms = 100

-- Forward-declared: arm_ghostty_retransmit_timer's timer callback needs
-- ghostty_retransmit_pass to already exist, but ghostty_retransmit_pass's
-- own bounded-retry branch (see its comment below) needs to call back into
-- arm_ghostty_retransmit_timer — the same forward-declaration cycle
-- schedule_redraw/redraw_all below resolves the same way.
local ghostty_retransmit_pass

local function arm_ghostty_retransmit_timer()
  if not ghostty_retransmit_timer then
    ghostty_retransmit_timer = vim.uv.new_timer()
  end
  ghostty_retransmit_timer:stop()
  ghostty_retransmit_timer:start(
    M._ghostty_settle_ms,
    0,
    vim.schedule_wrap(ghostty_retransmit_pass)
  )
end

-- A handle can still be `ghostty_entry_stale()` after this pass runs:
-- `retransmit_and_place()` itself can fail (e.g. `write_all()` exhausted its
-- bounded EAGAIN retries), or `compute_placement()` can come back `nil` for
-- this one settle-timer tick even though the handle's cache entry is still
-- stale — a real drag-resize's tail end can still race `vim.fn.screenpos()`
-- (see its pcall guard in `compute_placement`) at the exact moment the
-- settle timer fires. Nothing else ever revisits a stale handle once its
-- cache entry says stale and no further `WinResized`/`WinScrolled` happens
-- to arrive, so without a retry here the placement stays blank until the
-- user happens to resize again (issue #37) — purely a matter of luck, not a
-- permanent loss. This mirrors `DESTROY_DELETE_RETRIES` above (issue #27) in
-- spirit: same shape of problem, an escape-sequence-driven recovery with no
-- response to confirm success by (`q=2` suppresses all of them), so a
-- bounded self-reschedule is the only way back that doesn't depend on an
-- unrelated future event. Unlike `pending_deletes`' per-entry budget, this
-- one budget is shared across every handle a settle-timer pass retries —
-- each pass already retries all currently-stale handles together (mirroring
-- `redraw_all`'s own batched-per-pass shape), so every stale handle still
-- gets up to `GHOSTTY_RETRANSMIT_RETRIES` + 1 total attempts regardless of
-- how many other handles are stale alongside it. Bounded, not indefinite,
-- so a handle that's genuinely gone (e.g. its window closed) can't keep the
-- timer alive forever, preserving AGENTS.md's "fully quiescent idle" rule.
local GHOSTTY_RETRANSMIT_RETRIES = 3
local ghostty_retransmit_retries_left = GHOSTTY_RETRANSMIT_RETRIES

ghostty_retransmit_pass = function()
  local caps = M._detect_fn()
  local still_stale = false
  for _, handle in ipairs(M._handles) do
    if ghostty_entry_stale(handle, caps.terminal) then
      local placement = compute_placement(handle)
      if not (placement and retransmit_and_place(handle, placement)) then
        still_stale = true
      end
    end
  end
  if still_stale and ghostty_retransmit_retries_left > 0 then
    ghostty_retransmit_retries_left = ghostty_retransmit_retries_left - 1
    arm_ghostty_retransmit_timer()
  end
end

local function schedule_ghostty_retransmit()
  ghostty_retransmit_retries_left = GHOSTTY_RETRANSMIT_RETRIES
  arm_ghostty_retransmit_timer()
end

-- Redraw (debounced, never transmits except Ghostty's resize self-heal) ------

local debounce_timer = nil
local debounce_ms = 16

-- Forward-declared: redraw_all's pending-delete retry branch below needs to
-- self-schedule another pass, but schedule_redraw's own definition (right
-- after redraw_all) needs redraw_all to already exist as its timer
-- callback — declaring the local up front breaks that cycle.
local schedule_redraw

local function redraw_all()
  local caps = M._detect_fn()

  -- Forces the same synchronous screen redraw M.show() already forces before
  -- its own first placement (issue #19) — Neovim's own redraw-to-tty output
  -- is scheduled asynchronously, and right after a real terminal resize
  -- (WinResized fired by an actual SIGWINCH, not a synthetic autocmd/test
  -- resize) `vim.fn.screenpos()` below can still race ahead of it and report
  -- a stale, invisible position for a handle that is geometrically fine.
  -- Previously this only ever cost one throwaway `a=d` (self-healing next
  -- pass, since redraw_all never transmitted), but issue #34's Ghostty
  -- retransmit path below only ever runs on the `visible` branch — without
  -- forcing the redraw here first, a real Ghostty resize could sit
  -- permanently invisible until some unrelated later event (e.g. a scroll)
  -- happened to land after Neovim's own internal redraw had caught up on
  -- its own. Scoped to Ghostty only: kitty/WezTerm never hit that permanent-
  -- invisible failure mode (the throwaway a=d self-heal above already covers
  -- them), so forcing this synchronous redraw on every debounced pass for
  -- them too would add cost with no correctness benefit.
  if discards_pixels_on_resize(caps.terminal) then
    M._redraw_fn()
  end

  for _, handle in ipairs(M._handles) do
    local placement = compute_placement(handle)
    if placement then
      if ghostty_entry_stale(handle, caps.terminal) then
        place_existing(handle, placement)
        schedule_ghostty_retransmit()
      else
        place_existing(handle, placement)
      end
    else
      -- Resend the hide command unconditionally, even if handle.visible is
      -- already false from a prior pass — a successful M._write_fn() call
      -- only means the delete bytes reached the tty, not that the terminal
      -- actually erased the pixels on screen. WezTerm's known scroll-driven
      -- rendering lag (docs/spec/kitty-graphics.md's Per-terminal quirks)
      -- can leave a placement's a=d unprocessed/stuck; without a retry here
      -- there is no other path back to a correct screen state since redraw
      -- passes are the only place hide is triggered (issue #23). This is
      -- the same "reissue every pass regardless of prior state" treatment
      -- place_existing already gets on the visible branch above, and is
      -- equally cheap: no pixel payload, escape-sequence bytes only.
      hide_existing(handle)
    end
  end

  if #pending_deletes > 0 then
    local still_pending = {}
    for _, pending in ipairs(pending_deletes) do
      M._write_fn({ terminal.build_delete(pending.id) })
      pending.retries = pending.retries - 1
      if pending.retries > 0 then
        table.insert(still_pending, pending)
      end
    end
    pending_deletes = still_pending
    if #pending_deletes > 0 then
      schedule_redraw()
    end
  end
end

function schedule_redraw()
  if not debounce_timer then
    debounce_timer = vim.uv.new_timer()
  end
  debounce_timer:stop()
  debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(redraw_all))
end

-- Lifecycle: destroy ------------------------------------------------------

---@param handle blit.Handle
---@param opts? { free_data?: boolean }
local function destroy_handle(handle, opts)
  local free_data = (opts and opts.free_data) or false

  if vim.api.nvim_buf_is_valid(handle.buf) then
    pcall(vim.api.nvim_buf_del_extmark, handle.buf, ensure_namespace(), handle.extmark_id)
  end

  for i, h in ipairs(M._handles) do
    if h == handle then
      table.remove(M._handles, i)
      break
    end
  end

  M._write_fn({ terminal.build_delete(handle.id, { free_data = free_data }) })

  if free_data then
    free_id(handle.id)
    drop_cache_entry(handle.cache_key, handle.id)
  else
    mark_cache_entry_idle(handle.cache_key, handle.id)
    -- Only the free_data=false path (clear()/clear_all(), BufWinLeave,
    -- WinClosed, BufWipeout) gets a retry: its id stays reserved and its
    -- cache entry stays around for reuse, so a late retry always still
    -- refers to either this same dead placement or nothing (cancelled via
    -- cancel_pending_delete if acquire_idle_entry reclaims the id first).
    -- VimLeavePre's free_data=true call frees the id immediately, so a
    -- queued retry there could race a reused id after Neovim exits/the
    -- process is gone anyway — not worth the risk for a shutdown path.
    table.insert(pending_deletes, { id = handle.id, retries = DESTROY_DELETE_RETRIES })
    schedule_redraw()
  end
end

local autocmds_ready = false

local function maybe_teardown_autocmds()
  if #M._handles > 0 or #pending_deletes > 0 then
    return
  end
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
  end
  if ghostty_retransmit_timer then
    ghostty_retransmit_timer:stop()
    ghostty_retransmit_timer:close()
    ghostty_retransmit_timer = nil
  end
  if autocmds_ready then
    pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
    autocmds_ready = false
  end
end

---@param buf integer
---@param win? integer
local function destroy_matching(buf, win)
  local to_destroy = {}
  for _, handle in ipairs(M._handles) do
    if handle.buf == buf and (win == nil or handle.win == win) then
      table.insert(to_destroy, handle)
    end
  end
  for _, handle in ipairs(to_destroy) do
    destroy_handle(handle, { free_data = false })
  end
  maybe_teardown_autocmds()
end

---@param win integer
local function destroy_handles_for_win(win)
  local to_destroy = {}
  for _, handle in ipairs(M._handles) do
    if handle.win == win then
      table.insert(to_destroy, handle)
    end
  end
  for _, handle in ipairs(to_destroy) do
    destroy_handle(handle, { free_data = false })
  end
  maybe_teardown_autocmds()
end

local function on_vim_leave_pre()
  local handles = vim.list_extend({}, M._handles)
  for _, handle in ipairs(handles) do
    destroy_handle(handle, { free_data = true })
  end
  maybe_teardown_autocmds()
  terminal.reset_writer()
end

local function ensure_autocmds()
  if autocmds_ready then
    return
  end
  autocmds_ready = true
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "TabEnter", "TabLeave" }, {
    group = group,
    callback = schedule_redraw,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    callback = function(args)
      destroy_matching(args.buf, vim.api.nvim_get_current_win())
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      destroy_handles_for_win(tonumber(args.match))
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      destroy_matching(args.buf, nil)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = on_vim_leave_pre,
  })
end

---@param v any
---@return boolean
local function is_positive_integer(v)
  return type(v) == "number" and v == math.floor(v) and v > 0
end

-- Public API ------------------------------------------------------------------

---@class blit.ShowOpts
---@field width integer target placement width in cell columns
---@field height integer target placement height in cell rows
---@field buf? integer defaults to the current buffer of {win}
---@field win? integer defaults to the current window
---@field lnum? integer 1-indexed anchor line, defaults to {win}'s cursor line
---@field col? integer 0-indexed anchor byte column, defaults to 0; currently
---unused for placement (virt_lines always render at the window's text-area
---left edge) — reserved for future use
---@field z_index? integer
---@field max_file_bytes? integer defaults to blit.config.defaults.max_file_bytes
---@field debounce_ms? integer defaults to the last configured value (initially 16)

---@param path string
---@param opts blit.ShowOpts
---@return blit.Handle? handle
---@return string? err
function M.show(path, opts)
  vim.validate({ path = { path, "string" }, opts = { opts, "table" } })
  vim.validate({
    width = { opts.width, is_positive_integer, "a positive integer (cell columns)" },
    height = { opts.height, is_positive_integer, "a positive integer (cell rows)" },
    buf = { opts.buf, "number", true },
    win = { opts.win, "number", true },
    lnum = { opts.lnum, "number", true },
    col = { opts.col, "number", true },
    z_index = { opts.z_index, "number", true },
    max_file_bytes = { opts.max_file_bytes, "number", true },
    debounce_ms = { opts.debounce_ms, "number", true },
  })

  local caps = M._detect_fn()
  if not caps.supported then
    return nil, "blit: unsupported environment (" .. (caps.reason or "unknown") .. ")"
  end

  local stat, stat_err = vim.uv.fs_stat(path)
  if not stat then
    return nil, "blit: cannot stat " .. path .. ": " .. tostring(stat_err)
  end

  local max_bytes = opts.max_file_bytes or config.defaults.max_file_bytes
  if stat.size > max_bytes then
    return nil,
      "blit: " .. path .. " exceeds max_file_bytes (" .. stat.size .. " > " .. max_bytes .. ")"
  end

  local win = opts.win or vim.api.nvim_get_current_win()
  local buf = opts.buf or vim.api.nvim_win_get_buf(win)
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(win)[1]
  local col = opts.col or 0

  debounce_ms = opts.debounce_ms or debounce_ms

  local key = cache_key(path, stat.mtime)
  local entry = acquire_idle_entry(key, caps.terminal)

  local id, bytes, needs_transmit, native_width, native_height
  if entry then
    id = entry.id
    native_width = entry.native_width
    native_height = entry.native_height
    needs_transmit = false
  else
    local read_err
    bytes, read_err = read_file(path)
    if not bytes then
      return nil, read_err
    end
    -- Only IHDR metadata (native pixel width/height) is read here, for
    -- source-rect crop math (docs/spec/renderer-placement.md) — never a
    -- full PNG decode. This also newly rejects a non-PNG/corrupt file with
    -- nil, err before any bytes are ever transmitted, where previously
    -- show() would silently send garbage to the terminal.
    local dims, dims_err = png.read_ihdr(bytes)
    if not dims then
      return nil, dims_err
    end
    local alloc_err
    id, alloc_err = alloc_id()
    if not id then
      return nil, alloc_err
    end
    native_width = dims.width
    native_height = dims.height
    register_cache_entry(key, id, native_width, native_height)
    needs_transmit = true
  end

  local ns = ensure_namespace()
  local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
    virt_lines = build_virt_lines(opts.height),
  })

  ---@type blit.Handle
  local handle = {
    id = id,
    buf = buf,
    win = win,
    extmark_id = extmark_id,
    path = path,
    cache_key = key,
    geometry = { lnum = lnum, col = col, cols = opts.width, rows = opts.height },
    z_index = opts.z_index,
    visible = false,
    native_width = native_width,
    native_height = native_height,
  }
  table.insert(M._handles, handle)
  ensure_autocmds()
  M._redraw_fn()

  local placement = compute_placement(handle)

  if needs_transmit then
    local sequences = {}
    if placement then
      table.insert(sequences, terminal.build_save_cursor())
      table.insert(
        sequences,
        terminal.build_move_cursor(placement.screen_row, placement.screen_col)
      )
      vim.list_extend(
        sequences,
        terminal.build_transmit(
          bytes,
          { id = id, action = "T", placement = placement_opts(handle, placement) }
        )
      )
      table.insert(sequences, terminal.build_restore_cursor())
    else
      vim.list_extend(sequences, terminal.build_transmit(bytes, { id = id, action = "t" }))
    end
    local ok, err = M._write_fn(sequences)
    if not ok then
      destroy_handle(handle, { free_data = true })
      maybe_teardown_autocmds()
      return nil, err
    end
    handle.visible = placement ~= nil
  elseif placement then
    local ok, err = place_existing(handle, placement)
    if not ok then
      destroy_handle(handle, { free_data = true })
      maybe_teardown_autocmds()
      return nil, err
    end
  end

  -- A newly-anchored virt_lines block can shift the screen position of
  -- every handle anchored below/around it in the same window. Catch up any
  -- pre-existing handles via the same debounced redraw pass used for
  -- WinScrolled/WinResized; redraw_all() never transmits, so including the
  -- handle just created above is safe (issue #18).
  if #M._handles > 1 then
    schedule_redraw()
  end

  return handle
end

---@param handle blit.Handle
function M.clear(handle)
  vim.validate({ handle = { handle, "table" } })
  destroy_handle(handle, { free_data = false })
  maybe_teardown_autocmds()
end

function M.clear_all()
  local handles = vim.list_extend({}, M._handles)
  for _, handle in ipairs(handles) do
    destroy_handle(handle, { free_data = false })
  end
  maybe_teardown_autocmds()
end

-- Test-only: fully reset module state (including freeing terminal-side data)
-- so tests don't leak ids/cache entries/autocmds across cases.
function M._reset()
  local handles = vim.list_extend({}, M._handles)
  for _, handle in ipairs(handles) do
    destroy_handle(handle, { free_data = true })
  end
  M._handles = {}
  -- Discard any still-outstanding destroy-path retries (see "Destroy-path
  -- delete retry queue") before the teardown check below, so a clear()
  -- mid-retry in one test case can never leave the debounce timer running
  -- into the next case.
  pending_deletes = {}
  maybe_teardown_autocmds()
  cache = {}
  used_ids = {}
  next_id = terminal.ID_RANGE_START
  M._write_fn = function(sequences)
    return terminal.write(sequences)
  end
  M._detect_fn = terminal.detect
  M._redraw_fn = function()
    vim.cmd("redraw")
  end
  M._ghostty_settle_ms = 100
end

return M
