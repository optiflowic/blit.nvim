-- Kitty graphics protocol layer. See docs/spec/kitty-graphics.md and
-- docs/spec/terminal-detection.md — implementation here must match those
-- memos; if reality diverges, fix the memo in the same change.
--
-- This module knows nothing about buffers, windows, or extmarks.

local M = {}

local ESC = string.char(27)
local APC_START = ESC .. "_G"
local APC_END = ESC .. "\\"

---@alias blit.terminal.Action "T"|"t"

---@class blit.terminal.PlacementOpts
---@field columns? integer
---@field rows? integer
---@field z_index? integer
---@field no_move_cursor? boolean

---@class blit.terminal.TransmitOpts
---@field id integer
---@field action? blit.terminal.Action  -- default "T"
---@field quiet? 0|1|2                  -- default 2
---@field placement? blit.terminal.PlacementOpts

---@param parts { [1]: string, [2]: string|integer }[]
---@return string
local function build_control(parts)
  local out = {}
  for i, kv in ipairs(parts) do
    out[i] = kv[1] .. "=" .. tostring(kv[2])
  end
  return table.concat(out, ",")
end

---@param opts? blit.terminal.PlacementOpts
---@param parts { [1]: string, [2]: string|integer }[]
local function append_placement_parts(parts, opts)
  if not opts then
    return
  end
  if opts.columns then
    parts[#parts + 1] = { "c", opts.columns }
  end
  if opts.rows then
    parts[#parts + 1] = { "r", opts.rows }
  end
  if opts.z_index then
    parts[#parts + 1] = { "z", opts.z_index }
  end
  if opts.no_move_cursor then
    parts[#parts + 1] = { "C", 1 }
  end
end

-- Escape-sequence construction (pure, no I/O) -------------------------------

M.CHUNK_SIZE = 4096

---@param base64_payload string
---@param chunk_size? integer
---@return string[] chunks
function M.chunk_base64(base64_payload, chunk_size)
  chunk_size = chunk_size or M.CHUNK_SIZE
  if base64_payload == "" then
    return { "" }
  end
  local chunks = {}
  for i = 1, #base64_payload, chunk_size do
    chunks[#chunks + 1] = base64_payload:sub(i, i + chunk_size - 1)
  end
  return chunks
end

---@param png_bytes string
---@param opts blit.terminal.TransmitOpts
---@return string[] sequences
function M.build_transmit(png_bytes, opts)
  vim.validate({
    png_bytes = { png_bytes, "string" },
    opts = { opts, "table" },
    id = { opts.id, M.is_valid_id, "a valid id in blit's reserved range" },
    action = {
      opts.action,
      function(v)
        return v == nil or v == "T" or v == "t"
      end,
      '"T" or "t"',
    },
    quiet = {
      opts.quiet,
      function(v)
        return v == nil or v == 0 or v == 1 or v == 2
      end,
      "0, 1, or 2",
    },
  })

  local action = opts.action or "T"
  local quiet = opts.quiet
  if quiet == nil then
    quiet = 2
  end

  local payload = vim.base64.encode(png_bytes)
  local chunks = M.chunk_base64(payload)

  local sequences = {}
  for i, chunk in ipairs(chunks) do
    local more = (i < #chunks) and 1 or 0
    local control
    if i == 1 then
      local parts = {
        { "a", action },
        { "f", 100 },
        { "t", "d" },
        { "i", opts.id },
        { "q", quiet },
      }
      append_placement_parts(parts, opts.placement)
      parts[#parts + 1] = { "m", more }
      control = build_control(parts)
    else
      control = "m=" .. more
    end
    sequences[#sequences + 1] = APC_START .. control .. ";" .. chunk .. APC_END
  end
  return sequences
end

---@param id integer
---@param opts? blit.terminal.PlacementOpts
---@return string sequence
function M.build_placement(id, opts)
  vim.validate({ id = { id, M.is_valid_id, "a valid id in blit's reserved range" } })
  local parts = { { "a", "p" }, { "i", id } }
  append_placement_parts(parts, opts)
  return APC_START .. build_control(parts) .. APC_END
end

---@param id integer
---@param opts? { free_data?: boolean }
---@return string sequence
function M.build_delete(id, opts)
  vim.validate({ id = { id, M.is_valid_id, "a valid id in blit's reserved range" } })
  local d = (opts and opts.free_data) and "I" or "i"
  local parts = { { "a", "d" }, { "d", d }, { "i", id } }
  return APC_START .. build_control(parts) .. APC_END
end

-- Cursor positioning ----------------------------------------------------------
-- Regular (non-unicode-placeholder) kitty placements render at the
-- terminal's current cursor position at the moment the placement command is
-- processed. renderer.lua saves the cursor, moves it to the computed screen
-- cell, emits the placement, then restores it — see
-- docs/spec/renderer-placement.md for why this is safe to interleave with
-- Neovim's own cursor/redraw handling.

---@return string
function M.build_save_cursor()
  return ESC .. "7"
end

---@return string
function M.build_restore_cursor()
  return ESC .. "8"
end

---@param v any
---@return boolean
local function is_positive_integer(v)
  return type(v) == "number" and v == math.floor(v) and v > 0
end

---@param row integer 1-indexed screen row
---@param col integer 1-indexed screen column
---@return string
function M.build_move_cursor(row, col)
  vim.validate({
    row = { row, is_positive_integer, "a positive integer" },
    col = { col, is_positive_integer, "a positive integer" },
  })
  return ESC .. "[" .. row .. ";" .. col .. "H"
end

-- Reserved image ID range ----------------------------------------------------
-- Range ownership: terminal.lua exposes only these protocol-level facts.
-- The stateful counter that hands out ids from this range belongs to
-- renderer.lua (it owns the handle table), per AGENTS.md's architecture.

M.ID_RANGE_START = 0x626C0000
M.ID_RANGE_END = 0x626CFFFF

---@param id any
---@return boolean
function M.is_valid_id(id)
  if type(id) ~= "number" then
    return false
  end
  if id ~= math.floor(id) then
    return false
  end
  return id >= M.ID_RANGE_START and id <= M.ID_RANGE_END
end

-- Capability detection (pure, env/ttyout-injectable) -------------------------

---@param env? table<string, string?>
---@return "kitty"|"wezterm"|"ghostty"|nil
function M.detect_terminal(env)
  env = env or vim.env
  if env.KITTY_WINDOW_ID then
    return "kitty"
  end
  if env.TERM_PROGRAM == "WezTerm" then
    return "wezterm"
  end
  if env.TERM_PROGRAM == "ghostty" then
    return "ghostty"
  end
  return nil
end

---@param env? table<string, string?>
---@return boolean
function M.has_tmux(env)
  env = env or vim.env
  return env.TMUX ~= nil
end

---@param ttyout? fun(): integer
---@return boolean is_gui_or_embed
function M.is_gui_embed(ttyout)
  ttyout = ttyout or function()
    return vim.fn.has("ttyout")
  end
  return ttyout() == 0
end

---@class blit.terminal.Capabilities
---@field terminal "kitty"|"wezterm"|"ghostty"|nil
---@field tmux boolean
---@field gui_embed boolean
---@field supported boolean
---@field reason? string

---@param env? table<string, string?>
---@param ttyout? fun(): integer
---@return blit.terminal.Capabilities
function M.detect(env, ttyout)
  local terminal = M.detect_terminal(env)
  local tmux = M.has_tmux(env)
  local gui_embed = M.is_gui_embed(ttyout)

  local supported = true
  local reason = nil

  if tmux then
    supported = false
    reason = "tmux"
  elseif gui_embed then
    supported = false
    reason = "gui_embed"
  elseif not terminal then
    supported = false
    reason = "unsupported_terminal"
  end

  return {
    terminal = terminal,
    tmux = tmux,
    gui_embed = gui_embed,
    supported = supported,
    reason = reason,
  }
end

-- tty transport ---------------------------------------------------------------
-- Never write to io.stdout: Neovim's UI protocol may be multiplexing that
-- stream, and it may be redirected. /dev/tty is the controlling terminal
-- device, independent of stdout, so it's tried first.
--
-- Fallback to /dev/fd/1: some Neovim + terminal combinations leave the
-- Neovim process without a controlling terminal even though detect()'s
-- has('ttyout') check confirms stdout is a real terminal (Neovim's startup
-- reclaims the pty via setsid()+TIOCSCTTY, and that reclaim can be rejected
-- by the kernel if the launching shell's session still holds the pty as its
-- own controlling terminal). /dev/tty is then unopenable (ENXIO) for the
-- rest of the process's life. /dev/fd/1 opens a duplicate of the
-- already-open, already-verified-real stdout fd by descriptor rather than
-- by controlling-terminal lookup, sidestepping the missing-ctty problem.
-- See docs/spec/terminal-detection.md.

---@alias blit.terminal.Writer fun(data: string): boolean, string?
---@alias blit.terminal.WriterFactory fun(): blit.terminal.Writer?, string?, (fun())?

local TTY_PATHS = { "/dev/tty", "/dev/fd/1" }

-- Overridable seam for tests: production code always goes through
-- vim.uv.fs_open; tests inject a stub so the /dev/tty -> /dev/fd/1 fallback
-- is exercisable without a real tty.
M._fs_open = function(path)
  return vim.uv.fs_open(path, "w", 438)
end

-- Overridable seam for tests: production code always goes through
-- vim.uv.fs_write; tests inject a stub to exercise EAGAIN retry and partial
-- write handling without a real fd.
M._fs_write = function(fd, data)
  return vim.uv.fs_write(fd, data)
end

local WRITE_MAX_EAGAIN_RETRIES = 50
local WRITE_EAGAIN_RETRY_SLEEP_MS = 1

-- /dev/fd/1 (see the fallback note above) can share its underlying open
-- file description's O_NONBLOCK flag with Neovim's own event-loop-driven
-- stdout, so a write can return EAGAIN under a large/bursty payload (e.g. a
-- multi-KB base64 image transmission) even though the fd is otherwise
-- healthy — retrying after a short sleep is the standard remedy. A single
-- fs_write is also not guaranteed to consume the whole buffer for a
-- tty/pipe fd, so partial writes are looped until fully flushed.
---@param fd integer
---@param data string
---@return boolean ok
---@return string? err
local function write_all(fd, data)
  local offset = 0
  local retries = 0
  while offset < #data do
    local n, write_err = M._fs_write(fd, offset == 0 and data or data:sub(offset + 1))
    if n then
      offset = offset + n
      retries = 0
    elseif write_err and vim.startswith(write_err, "EAGAIN") then
      retries = retries + 1
      if retries > WRITE_MAX_EAGAIN_RETRIES then
        return false,
          "blit.terminal: write still EAGAIN after " .. WRITE_MAX_EAGAIN_RETRIES .. " retries"
      end
      vim.uv.sleep(WRITE_EAGAIN_RETRY_SLEEP_MS)
    else
      return false, write_err
    end
  end
  return true
end

---@return blit.terminal.Writer?, string?, (fun())?
local function open_tty_writer()
  local last_err
  for _, path in ipairs(TTY_PATHS) do
    local fd, open_err = M._fs_open(path)
    if fd then
      local function writer(data)
        return write_all(fd, data)
      end
      local function close()
        vim.uv.fs_close(fd)
      end
      return writer, nil, close
    end
    last_err = open_err
  end
  return nil, last_err or "blit.terminal: unable to open a tty device"
end

-- Overridable seam: tests replace this to observe/control writer creation
-- without touching a real tty.
M._writer_factory = open_tty_writer

-- Cached across calls rather than reopened per write: measured via
-- vim.uv.hrtime() (macOS, N=2000 fs_open+fs_write+fs_close cycles vs. a
-- cached fd) at ~0.032ms/op open-per-call vs ~0.0015ms/op cached — about
-- 21x slower per call. See docs/spec/terminal-detection.md.
local cached_writer = nil
local cached_close = nil

---@param sequences string[]
---@param writer? blit.terminal.Writer
---@return boolean ok
---@return string? err
function M.write(sequences, writer)
  local active_writer = writer
  if not active_writer then
    if not cached_writer then
      local w, err, close = M._writer_factory()
      if not w then
        return false, err
      end
      cached_writer = w
      cached_close = close
    end
    active_writer = cached_writer
  end

  for _, seq in ipairs(sequences) do
    local ok, err = active_writer(seq)
    if not ok then
      return false, err
    end
  end
  return true
end

---@return nil
function M.reset_writer()
  if cached_close then
    cached_close()
  end
  cached_writer = nil
  cached_close = nil
end

return M
