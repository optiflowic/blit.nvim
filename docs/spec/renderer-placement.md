# Renderer Placement — blit.nvim

This memo documents the design `lua/blit/renderer.lua` implements: how a
buffer/window position becomes an on-screen kitty graphics placement, when an
image is considered visible, and how transmitted pixel data is cached and
freed. Per `AGENTS.md`'s Spec Memo Workflow, `renderer.lua` cites this memo;
if reality diverges, fix the memo in the same change. This is a companion to
`docs/spec/kitty-graphics.md` (protocol subset) and
`docs/spec/terminal-detection.md` (capability gating) — this memo covers the
layer above both: `renderer.lua` calls `terminal.lua`'s pure builders, it
never constructs escape sequences itself.

## Reserving space: virt_lines

`show()` creates one extmark per handle, anchored at the caller's `lnum`
(1-indexed) with `opts.height` empty `virt_lines` attached. The anchor
buffer line itself is left untouched (e.g. a markdown `![alt](path)` line
stays intact); the image renders into the reserved blank lines immediately
below it. `opts.width`/`opts.height` are cell counts (columns/rows) the
caller must supply explicitly — v0.x does not read the PNG's pixel
dimensions or attempt aspect-ratio-preserving auto-sizing, since kitty
placements are given explicit `c=`/`r=` cell targets and blit does not query
the terminal's cell-pixel size (that would require reading an async
protocol response, out of scope per `docs/spec/kitty-graphics.md`'s
"Response handling" section). One handle = one entry in `M._handles`,
shaped `{ id, buf, win, extmark_id, path, cache_key, geometry, z_index,
visible }`, matching `AGENTS.md`'s "one image = one handle table" rule.

## Screen coordinate conversion

`vim.fn.screenpos(win, lnum, col)` maps a buffer position to an absolute
screen row/col, or `row = 0` if that position is not currently rendered at
all (scrolled off, inside a closed fold, wrong window). `renderer.lua` calls
this with the anchor line, then adds 1 to the returned row to get the first
screen row of the reserved `virt_lines` block (they render immediately below
the anchor line's own rendered row).

**Known limitation**: this assumes the anchor line occupies exactly one
screen row. With `'wrap'` on and a long anchor line, the true virt_lines
start row is pushed down by however many extra wrapped rows the anchor line
takes — not computed here. Accepted for v0.x; revisit if real usage hits it
(matches the "known false-negative/false-positive risks" pattern used in
`docs/spec/terminal-detection.md`).

Window bounds (`top`, `bottom`, `left`, `right`, all 1-indexed absolute
screen coordinates) come from `nvim_win_get_position` + `nvim_win_get_height`
/ `nvim_win_get_width`. This is an approximation: winbar/statusline offsets
are not independently accounted for beyond what those two calls already
report.

## Visibility policy: fully visible or not shown at all

When an image's reserved row/col span is not **entirely** contained within
its window's current bounds, blit does not display it — no partial/cropped
placement. This was a deliberate scope decision (see project history): kitty
supports source-rectangle cropping (`x`,`y`,`w`,`h` on an existing
transmission) which could show a partial image when scrolled halfway into
view, but implementing it correctly requires proportional pixel-crop math
against the PNG's native dimensions and extending
`docs/spec/kitty-graphics.md` with those keys. Deferred until a future
version if the all-or-nothing behavior proves insufficient in practice.

The pure check (`fully_within(anchor, span, bound_start, bound_end)` in
`renderer.lua`, unit-tested directly) is: `anchor >= bound_start and anchor +
span - 1 <= bound_end`, applied independently to rows and columns; both must
hold.

## Positioning a placement: cursor save/move/restore

Non-unicode-placeholder kitty placements render at the terminal's current
cursor position at the time the command is processed — the same way writing
text places it at the cursor. To place at a computed screen cell without
disturbing Neovim's own cursor rendering, every placement/transmit-and-display
sequence is bracketed:

```
DECSC (save cursor)
CUP <row>;<col> (move cursor)
<kitty placement or transmit+display command, C=1 so kitty itself doesn't move it further>
DECRC (restore cursor)
```

This is safe to interleave with Neovim's own terminal cursor handling
because Neovim repositions the terminal cursor to match its internal
cursor row/col on every redraw cycle; the save/move/restore bracket around a
single write is transient and does not survive past that write.

Deletion (`a=d`) is not screen-position-dependent, so no cursor bracketing is
needed there.

## Transmission cache: (path, mtime) keyed, no placement-id fan-out

Cache key: `path .. ":" .. mtime.sec .. "." .. mtime.nsec` (from
`vim.uv.fs_stat`). Each cache entry is a **list** of `{ id, active }` pairs
for that exact file content — a list, not a single entry, because:

- `show()` on a cache hit with an **idle** (`active = false`) entry reuses
  that id: no re-transmission, just an `a=p` placement (or nothing yet, if
  not currently visible) — this is the AGENTS.md performance rule
  ("re-placement... must reuse its ID — never re-transmit").
- `show()` on a cache hit where every existing entry is **active** (already
  placed live somewhere else) transmits a fresh copy under a new id instead
  of reusing/relocating the active one. **v0.x does not implement kitty's
  placement-id (`p=`) key**, so a given image id has only one implicit
  placement; reusing an active id for a second simultaneous location would
  silently move the first location's image instead of adding a second one.
  Supporting true multi-location fan-out for one transmitted image is
  deferred — it would require extending `docs/spec/kitty-graphics.md` with
  `p=` on placement/delete and is not needed for the common case (showing
  one image once, or showing it again after it was cleared).

Cache entries are never evicted except at `VimLeavePre` (or the test-only
`_reset()`) — an idle entry's id and terminal-side pixel data are kept
around so a later `show()` of the same file is cheap. **Known limitation**:
this means the id pool (65,536 ids, `docs/spec/kitty-graphics.md`'s reserved
range) is not reclaimed during a long session that `show()`s many distinct
files; unbounded growth is accepted for v0.x (mirrors that memo's own
acceptance of the range being merely "negligible collision risk", not
infinite). `alloc_id()` returns `nil, err` if the range is exhausted;
`show()` propagates that as a normal `nil, err_msg` failure.

## Lifecycle

Two distinct kinds of state transition, kept separate:

- **Redraw** (`WinScrolled`, `WinResized`, debounced by `config.debounce_ms`
  — single deferred recompute per burst, per AGENTS.md's performance rule):
  recomputes visibility/position for every still-anchored handle and
  toggles its placement (`a=p` to show/reposition, `a=d` to hide). Never
  transmits, never destroys a handle.
- **Destroy** (`BufWinLeave` for the specific `(buf, win)` pair,
  `WinClosed` for a closing window, `BufWipeout` for a wiped buffer,
  `M.clear()`/`M.clear_all()`, and `VimLeavePre`): removes the extmark,
  removes the handle from `M._handles`, marks its cache entry idle, and
  deletes its terminal-side placement. Only `VimLeavePre` (and
  `M.clear`/`M.clear_all`'s eventual full-teardown path) also frees the
  id back to the pool and the terminal's stored pixel data
  (`d=I`) — everyday `clear()` keeps the cache warm.

All autocmds live in one `augroup("blit", { clear = true })`; all extmarks in
one `nvim_create_namespace("blit")`, both created lazily on first `show()`
(zero-cost `require`/`setup()`, per AGENTS.md). When the last handle is
destroyed, the debounce timer is stopped/closed and the augroup is deleted —
fully quiescent idle, no dangling autocmds or timers, until the next
`show()` recreates them.
