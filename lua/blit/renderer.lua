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

---@type table<string, { id: integer, active: boolean }[]>
local cache = {}

---@param path string
---@param mtime { sec: integer, nsec: integer }
---@return string
local function cache_key(path, mtime)
  return path .. ":" .. mtime.sec .. "." .. mtime.nsec
end
M.cache_key = cache_key

---@param key string
---@return { id: integer, active: boolean }?
local function acquire_idle_entry(key)
  local entries = cache[key]
  if not entries then
    return nil
  end
  for _, entry in ipairs(entries) do
    if not entry.active then
      entry.active = true
      return entry
    end
  end
  return nil
end

---@param key string
---@param id integer
local function register_cache_entry(key, id)
  cache[key] = cache[key] or {}
  table.insert(cache[key], { id = id, active = true })
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
-- Pure integer math, unit-tested directly. v0.x policy: an image is either
-- fully visible or not shown at all — no partial/cropped placements. See
-- docs/spec/renderer-placement.md's "Visibility policy".

---@param anchor integer
---@param span integer
---@param bound_start integer
---@param bound_end integer
---@return boolean
local function fully_within(anchor, span, bound_start, bound_end)
  if anchor <= 0 then
    return false
  end
  return anchor >= bound_start and (anchor + span - 1) <= bound_end
end
M.fully_within = fully_within

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

---@param handle blit.Handle
---@return boolean visible
---@return integer? screen_row
---@return integer? screen_col
local function compute_placement(handle)
  if not vim.api.nvim_win_is_valid(handle.win) or not vim.api.nvim_buf_is_valid(handle.buf) then
    return false
  end
  if vim.api.nvim_win_get_buf(handle.win) ~= handle.buf then
    return false
  end
  -- screenpos() does not itself account for tab visibility: it keeps
  -- returning a window's real screen row/col even when that window's tab
  -- is not the currently active tabpage (verified) — so visibility must be
  -- checked explicitly here (issue #16).
  if vim.api.nvim_win_get_tabpage(handle.win) ~= vim.api.nvim_get_current_tabpage() then
    return false
  end

  -- virt_lines always render starting at the window's text-area left edge
  -- (the same screen column as byte column 1 of any line), independent of
  -- the extmark's own column — nvim_buf_set_extmark below anchors it at
  -- column 0 regardless of handle.geometry.col. Column 1 is queried here
  -- to match that, not handle.geometry.col (currently unused for
  -- placement; see the Geometry class doc comment).
  local ok, pos = pcall(vim.fn.screenpos, handle.win, handle.geometry.lnum, 1)
  if not ok or pos.row == 0 then
    return false
  end
  -- virt_lines render immediately below the anchor line's own screen row.
  local screen_row = pos.row + 1
  local screen_col = pos.col

  local bounds = window_bounds(handle.win)
  if not fully_within(screen_row, handle.geometry.rows, bounds.top, bounds.bottom) then
    return false
  end
  if not fully_within(screen_col, handle.geometry.cols, bounds.left, bounds.right) then
    return false
  end
  return true, screen_row, screen_col
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

-- Placement / hide --------------------------------------------------------

---@param handle blit.Handle
---@return blit.terminal.PlacementOpts
local function placement_opts(handle)
  return {
    columns = handle.geometry.cols,
    rows = handle.geometry.rows,
    z_index = handle.z_index,
    no_move_cursor = true,
  }
end

---@param handle blit.Handle
---@param row integer
---@param col integer
---@return boolean ok
---@return string? err
local function place_existing(handle, row, col)
  local sequences = {
    terminal.build_save_cursor(),
    terminal.build_move_cursor(row, col),
    terminal.build_placement(handle.id, placement_opts(handle)),
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

-- Redraw (debounced, never transmits, never destroys) ------------------------

local debounce_timer = nil
local debounce_ms = 16

local function redraw_all()
  for _, handle in ipairs(M._handles) do
    local visible, row, col = compute_placement(handle)
    if visible then
      place_existing(handle, row, col)
    elseif handle.visible then
      hide_existing(handle)
    end
  end
end

local function schedule_redraw()
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
  end
end

local autocmds_ready = false

local function maybe_teardown_autocmds()
  if #M._handles > 0 then
    return
  end
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
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
  local entry = acquire_idle_entry(key)

  local id, bytes, needs_transmit
  if entry then
    id = entry.id
    needs_transmit = false
  else
    local read_err
    bytes, read_err = read_file(path)
    if not bytes then
      return nil, read_err
    end
    local alloc_err
    id, alloc_err = alloc_id()
    if not id then
      return nil, alloc_err
    end
    register_cache_entry(key, id)
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
  }
  table.insert(M._handles, handle)
  ensure_autocmds()
  M._redraw_fn()

  local visible, screen_row, screen_col = compute_placement(handle)

  if needs_transmit then
    local sequences = {}
    if visible then
      table.insert(sequences, terminal.build_save_cursor())
      table.insert(sequences, terminal.build_move_cursor(screen_row, screen_col))
      vim.list_extend(
        sequences,
        terminal.build_transmit(
          bytes,
          { id = id, action = "T", placement = placement_opts(handle) }
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
    handle.visible = visible
  elseif visible then
    local ok, err = place_existing(handle, screen_row, screen_col)
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
  maybe_teardown_autocmds()
  M._handles = {}
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
end

return M
