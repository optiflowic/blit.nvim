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
this with the anchor line and column 1 — always column 1, never
`geometry.col` — then adds 1 to the returned row to get the first screen row
of the reserved `virt_lines` block (they render immediately below the
anchor line's own rendered row). Column 1 is used unconditionally because
`virt_lines` always render starting at the window's text-area left edge,
independent of the extmark's own column (the extmark itself is created at a
hardcoded column 0 below); `geometry.col`/`opts.col` is currently unused for
placement, reserved for a future version that supports horizontal
positioning some other way.

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

## Forcing a redraw before the first placement

`M.show()` calls `M._redraw_fn()` (production: `vim.cmd("redraw")`) right
after creating the handle's `virt_lines` extmark and before computing its
placement. This exists because blit writes kitty escape sequences directly
to the tty (`terminal.write()`), out of band from Neovim's own redraw-to-tty
output, which is scheduled asynchronously. Without forcing a synchronous
redraw first, the very first `show()` in a session could race ahead of
Neovim's own screen paint of the newly-reserved `virt_lines` rows, causing
the image to be positioned against a row that (from the real terminal's
point of view) hasn't been reserved yet — confirmed via manual testing
(issue #19): the image landed one row low, straddling the reserved block
and the following real buffer line, self-correcting only once some later
`WinScrolled`/`WinResized` event forced a real redraw anyway.

This is unobservable in headless `make test` runs: `vim.fn.screenpos()` was
verified (empirically, not assumed) to already return the post-extmark,
correct row synchronously in headless mode, with or without an interleaved
`vim.cmd("redraw")` call. The regression test in `tests/test_renderer.lua`
therefore asserts the pure-logic ordering contract (`_redraw_fn` is called
before `_write_fn`) rather than a position difference — the actual
pixel-level fix can only be confirmed on a real terminal, per
`docs/manual-testing.md`.

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

**Known limitation: a blank gap can flash during the scroll transition.**
`compute_placement` treats the anchor line as invisible once
`vim.fn.screenpos(win, lnum, 1)` returns `row = 0` (scrolled off), and
correctly stops placing/hides the image at that point (verified: the
`a=d`/`a=p` sequences blit sends are always correct — this is not a
protocol-layer bug). But Neovim's own `virt_lines` rendering does not
follow the same all-or-nothing rule: it treats a buffer line plus its
attached `virt_lines` as one scrollable block, so the window's topline can
land *inside* that block — showing the tail of the reserved blank rows on
screen even though the owning line's own `screenpos` already reports
fully off-screen. Since blit has (correctly, per the policy above) not
placed an image there, this reads as an empty gap at the top of the
window during the scroll transition, not a garbled/partial image. This is
the same root cause reported against `3rd/image.nvim` (see their issue
#213): there is no viewport API to ask "how many virtual rows above
topline are currently showing" without tracking scroll events yourself,
and even with that number in hand, closing the gap correctly requires
showing a genuinely cropped slice of the image (kitty's placement source
rectangle, `x`,`y`,`w`,`h` in pixels) — not just hiding or resizing
`virt_lines`, which does not make the missing pixels reappear and risks
its own topline/scroll feedback instability from resizing a line's height
while it's mid-scroll. Source-rectangle cropping is a real feature (PNG
pixel-dimension reading, new protocol keys, replacing the boolean
`fully_within` check with crop-amount math) and is intentionally deferred,
not implemented as part of the visibility policy above.

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
  of reusing/relocating the active one. blit does emit kitty's placement-id
  key (`p=`, always `terminal.PLACEMENT_ID`, a fixed constant — see
  `docs/spec/kitty-graphics.md`'s Placement section), but that fixed value
  only prevents ghost placements when *repositioning* an id's one
  placement; it is not a per-location identity. A given image id therefore
  still has only one live placement at a time — reusing an active id for a
  second simultaneous location would silently move the first location's
  image instead of adding a second one. Supporting true multi-location
  fan-out for one transmitted image (a distinct, allocated `p=` per
  location) is deferred and is not needed for the common case (showing one
  image once, or showing it again after it was cleared).

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
