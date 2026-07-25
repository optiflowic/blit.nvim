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
caller must supply explicitly and remain mandatory — blit reads the PNG's
*native pixel* dimensions (`lua/blit/png.lua`'s IHDR reader) solely to
support cropping a partially-visible placement (see "Visibility policy"
below), not for aspect-ratio-preserving auto-sizing: blit still does not
query the terminal's cell-pixel size (that would require reading an async
protocol response, out of scope per `docs/spec/kitty-graphics.md`'s
"Response handling" section), so there is no way to convert a native pixel
size into a cell count on blit's own. One handle = one entry in
`M._handles`, shaped `{ id, buf, win, extmark_id, path, cache_key, geometry,
z_index, visible, native_width, native_height }`, matching `AGENTS.md`'s
"one image = one handle table" rule.

**Known limitation**: a handle is bound to exactly one `win` at creation
time, but the `virt_lines` extmark carrying its reserved blank rows is
buffer-scoped, not window-scoped — Neovim renders those reserved rows in
*every* window currently showing that buffer. If the same buffer is split
into a second window (`:split`/`:vsplit`), the non-anchor window displays
the reserved blank space with no image in it, for as long as it stays
open — `compute_placement` only ever computes visibility/position against
the one `handle.win` it was given. A real fix requires per-window
placement-id fan-out (a distinct `p=` for each window showing the buffer),
which conflicts with the one-handle-per-placement data model above and is
already tracked separately (see "Transmission cache" below and issue #10,
"Multi-location placement fan-out for a single transmitted image").
Accepted for v0.x; revisit when #10 ships.

## Screen coordinate conversion

`vim.fn.screenpos(win, lnum, col)` maps a buffer position to an absolute
screen row/col, or `row = 0` if that position is not currently rendered at
all (scrolled off, inside a closed fold, wrong window). `renderer.lua` calls
this with the anchor line and column 1 — always column 1, never
`geometry.col` — to get the anchor's screen column and to test visibility.
Column 1 is used unconditionally because `virt_lines` always render starting
at the window's text-area left edge, independent of the extmark's own
column (the extmark itself is created at a hardcoded column 0 below);
`geometry.col`/`opts.col` is currently unused for placement, reserved for a
future version that supports horizontal positioning some other way.

The reserved `virt_lines` block's first screen row is one past the anchor
line's own **last** rendered screen row, not its first — under `'wrap'` a
long anchor line can span several screen rows, and `virt_lines` render below
all of them (issue #7). `anchor_last_row()` finds that last row by calling
`screenpos()` a second time, at the anchor line's own final byte column
instead of column 1: Neovim's display engine already maps a buffer column to
its wrapped screen row, accounting for `'breakindent'`/`'showbreak'`, so no
wrap-width math is duplicated here. If that second `screenpos()` call itself
reports `row = 0` (the wrap tail scrolled past the window's bottom edge,
while column 1 of the same line is still visible higher up), the reserved
block is entirely below the window too — `compute_placement` substitutes
`bounds.bottom` so the subsequent `compute_clip` call reports zero visible
rows, hiding the placement, matching what a real terminal would show.

**Verified quirk**: `screenpos()` does not account for tab visibility — it
keeps returning a window's real screen row/col even when that window
belongs to a currently *inactive* tabpage, instead of `row = 0`.
`compute_placement` therefore checks `nvim_win_get_tabpage(handle.win) ==
nvim_get_current_tabpage()` explicitly before trusting `screenpos()` at all
(issue #16) — without this, an image would stay frozen on screen after
switching away from its anchor window's tab (e.g. `:checkhealth`, which
opens its report in a new tab by default).

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

`M.show()` also calls the existing debounced `schedule_redraw()` at the end
of a successful call whenever more than one handle exists (see "Lifecycle"
below) — a newly-reserved `virt_lines` block can shift where every
*other*, already-placed handle in the same window now renders, and this
catches those up too (issue #18). `redraw_all()` never transmits, only
repositions/hides via `a=p`/`a=d`, so re-including the handle `show()` just
created in that same debounced pass is safe — the worst case is one
redundant, idempotent `a=p` for it.

## Visibility policy: partial visibility via source-rectangle cropping

An image is hidden entirely only when its reserved row/col span has **no
overlap at all** with its window's current bounds on either axis. When part
of the span is still within bounds, blit shows the visible slice as a
cropped placement (kitty's placement source rectangle, `x`,`y`,`w`,`h` — see
`docs/spec/kitty-graphics.md`'s "Source-rectangle cropping") rather than
hiding the whole thing. This replaced the original v0.1 all-or-nothing
policy, which caused the scroll-transition blank-gap limitation described
below.

The clip-amount computation (`compute_clip(anchor, span, bound_start,
bound_end)` in `renderer.lua`, unit-tested directly) returns three values:
`clip_low` (cells clipped from the top/left end), `clip_high` (cells clipped
from the bottom/right end), and `visible_span` (`0` if there's no overlap at
all). Applied independently to rows and columns; the placement is hidden if
either axis's `visible_span` is `0`. `fully_within(anchor, span, bound_start,
bound_end)` (the original check) is kept as a thin wrapper — `clip_low == 0
and clip_high == 0 and visible_span == span` — so it still answers "is this
completely unclipped", used where only a yes/no answer is needed.

`pixel_crop(clip_low_cells, clip_high_cells, total_cells, native_px)`
converts a cell-based clip amount into the proportional pixel offset/size
against the image's *native* pixel dimensions (from `lua/blit/png.lua`'s
IHDR reader — metadata only, never a full PNG decode, so this doesn't touch
the PNG-only/zero-dependency constraints): `offset_px = floor(clip_low_cells
* native_px / total_cells)`, `size_px = native_px - offset_px -
floor(clip_high_cells * native_px / total_cells)`. This is guaranteed to
never produce a non-positive `size_px` when `visible_span > 0`: since
`clip_low_cells + clip_high_cells < total_cells` (strictly, by definition of
a positive `visible_span`), `floor(a) + floor(b) <= floor(a+b)` bounds the
two subtracted terms' sum strictly below `native_px`, leaving at least `1`.
`x`/`y`/`w`/`h` are only emitted (via `terminal.lua`'s `PlacementOpts`) when
at least one axis is actually clipped — an unclipped placement pays no extra
escape-sequence bytes, matching the existing conditional-emission pattern
for `z=`/`C=1`. The target `c=`/`r=` also shrink to the visible cell span
when clipped, so the cropped slice renders at the correct size instead of
being stretched to fill the placement's original box.

**Resolved: the scroll-transition blank gap (was: "a blank gap can flash
during the scroll transition").** `compute_placement` used to treat the
anchor line as invisible the moment `vim.fn.screenpos(win, lnum, 1)`
returned `row = 0` (scrolled off) — correct as far as it went (the `a=d`
sequence sent at that point was always right), but Neovim's own `virt_lines`
rendering does not follow the same all-or-nothing rule: it treats a buffer
line plus its attached `virt_lines` as one scrollable block, so the window's
topline can land *inside* that block, showing the tail of the reserved rows
on screen even though the owning line's own `screenpos` already reports
fully off-screen. This is the same root cause reported against
`3rd/image.nvim` (issue #213).

The fix required a genuinely different signal than `screenpos`, since
`screenpos` on an off-screen line can never report *how far* off-screen it
is. Confirmed empirically (headless `nvim`, a `virt_lines`-bearing extmark,
gradual `<C-e>` scrolling): `vim.fn.winsaveview().topfill` counts down from
the reserved row count to `0` as the window scrolls through a handle's
`virt_lines` block, populated whenever the window's `topline` has landed
exactly on the line right after the anchor (the same mechanism diff-mode
filler lines use, just also populated here). `compute_placement` now
branches on this: when `screenpos(win, lnum, 1).row > 0`, row-clipping uses
the normal `compute_clip` path against the window's bounds as described
above. When it's `0`, a fallback checks `winsaveview().topline ==
handle.geometry.lnum + 1 and winsaveview().topfill > 0`; if true,
`clip_low = geometry.rows - topfill`, the visible tail starts at the
window's own top edge (`bounds.top`), and the remaining bottom-clip/pixel-
crop math is identical to the normal path. The column for this branch comes
from `screenpos(win, view.topline, 1)` (the line right after the anchor,
guaranteed visible whenever this branch is reached) rather than the
anchor's own — both render `virt_lines` at the same window text-area left
edge. If `topline` doesn't match exactly or `topfill` is `0`, the block has
genuinely scrolled fully past and the handle is correctly hidden, same as
before.

`topfill` is a per-window count, not a per-extmark one — if a second
handle's `virt_lines` block were anchored at this handle's own `lnum` (two
handles on the same buffer line), `topfill` would reflect their combined
row counts and could not be attributed to either handle alone.
`compute_placement` guards against this specific case
(`has_sibling_at_same_lnum`): if any other handle shares this handle's
`buf`/`lnum`, the fallback branch treats the handle as hidden rather than
risk a wrong crop. **Known limitation, not guarded against**: `topfill` is
also populated by Neovim's own diff-mode filler lines, which use the exact
same mechanism but aren't a blit handle at all — in diff mode, a filler
line landing at exactly `topline == handle.geometry.lnum + 1` could still
be misread as this handle's own reserved rows. Narrow (requires diff mode
active on a buffer with a cropped image at that precise scroll position)
and not currently detected or tested.

**Known limitation, much narrower than before: only the normal debounce
latency remains.** A scroll burst faster than `config.debounce_ms` (default
16ms) can still show one stale frame before the crop catches up to the
latest scroll position — the same general debounce-latency characteristic
already true of every other `WinScrolled` response in the plugin, not a new
caveat specific to cropping.

**Assumed, pending manual verification**: re-issuing `a=p` with no crop keys
at all (a previously-cropped placement now fully back in view) is expected
to reset the placement to the complete, uncropped image rather than
retaining a stale crop rectangle — see `docs/spec/kitty-graphics.md`'s
"Source-rectangle cropping" section and `docs/manual-testing.md` for the
verification step and fallback if this assumption is wrong on some
terminal.

**Known limitation: a stuck `a=d` can leave clipped pixels on WezTerm past
the window edge.** Distinct from the blank-gap flash above, this is a
persistent *bleed* of real image pixels rather than an absent placement —
observed when the window's bottom edge lands partway through a handle's
reserved `virt_lines` rows (issue #23). blit's own `a=d`/`a=p` sequences are
verified correct at the point they're sent; this is WezTerm-side rendering
lag under scroll (`docs/spec/kitty-graphics.md`'s Per-terminal quirks). See
"Lifecycle" below for the mitigation (`a=d` reissued every redraw pass a
handle is invisible, not just on the transition) — this reduces how long
the stuck state can persist but is not a guaranteed fix, since blit has no
way to confirm a given `a=d` actually took visible effect (`q=2` suppresses
terminal responses).

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
`vim.uv.fs_stat`). Each cache entry is a **list** of `{ id, active, lines,
columns, native_width, native_height }` entries for that exact file content
— a list, not a single entry, because:

`native_width`/`native_height` (the PNG's native pixel dimensions, read once
via `lua/blit/png.lua`'s IHDR reader when the file is actually read for
transmission) are populated at `register_cache_entry` time and copied onto
every handle that reuses the entry — a cache hit never re-reads or
re-parses the file. These are used solely by `pixel_crop` (see "Visibility
policy" above), never for auto-sizing.

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

Cache entries are otherwise never evicted except at `VimLeavePre` (or the
test-only `_reset()`) — an idle entry's id and terminal-side pixel data are
kept around so a later `show()` of the same file is cheap. **Known
limitation**: this means the id pool (65,536 ids,
`docs/spec/kitty-graphics.md`'s reserved range) is not reclaimed during a
long session that `show()`s many distinct files; unbounded growth is
accepted for v0.x (mirrors that memo's own acceptance of the range being
merely "negligible collision risk", not infinite). `alloc_id()` returns
`nil, err` if the range is exhausted; `show()` propagates that as a normal
`nil, err_msg` failure.

**Ghostty exception: idle entries recorded against a stale terminal size
are evicted eagerly, at reuse time.** Ghostty discards previously-
transmitted image data behind an id across a real terminal window resize,
silently — there is no error response to detect it by (`q=2` suppresses
all responses, `docs/spec/kitty-graphics.md`'s "Response handling"), and
`:checkhealth blit` still reports the terminal as supported. Reusing such
an id for a placement-only `a=p` then renders nothing (issue #24). Each
cache entry therefore also records `vim.o.lines`/`vim.o.columns` (the whole
Neovim grid size, which tracks the real terminal's size — not a per-window
size) at the moment of transmission. `acquire_idle_entry` compares an idle
entry's recorded size against the current size only when `caps.terminal ==
"ghostty"`; a mismatch means a resize happened at some point since
transmission, so the entry is treated as dead: its id is freed back to the
pool, the entry is dropped, and the scan continues to the next idle entry
(or falls through to a fresh transmit under a new id if none remain) rather
than handing out a placement-only reuse with nothing behind it.

This is a lazy, reuse-time size comparison rather than a `VimResized`
autocmd listener. A `VimResized`-based design was considered first but
rejected: it would need to keep listening even while zero handles exist
(the bug's own repro is `clear_all()` → resize → `show()` again), which
means a persistent autocmd outside the handle-gated `augroup` — directly
conflicting with AGENTS.md's "no timers or autocmds active when zero
images are displayed" performance rule. The size-comparison approach needs
no autocmd at all: it only ever runs inside `show()`'s own
`acquire_idle_entry` call. **Accepted false negative**: if the terminal is
resized away and back to the *exact* original `lines`/`columns` before the
next `show()`, the comparison can't tell that a resize happened in
between, and a dead entry could still be handed out. This is deemed rare
enough to accept for v0.x; a `VimResized`-driven design would close it at
the cost of the performance-rule conflict above, and is not pursued here
without revisiting that rule. Kitty and WezTerm are unaffected either way
— `terminal_name ~= "ghostty"` short-circuits the check, so their existing
idle-cache-reuse behavior and cost are unchanged.

**Ghostty exception, part two: a still-visible handle is re-transmitted
under a fresh id once a resize is detected and has settled.** The
mitigation above only covers a handle that gets cleared before the next
`show()` — it left a handle that stays visible/active across a Ghostty
resize (never cleared) uncovered, and issue #34 confirmed this actually
happens: the placement goes permanently blank on the very next resize,
with no `:redraw!`, scroll-out/scroll-back, or further resize able to
restore it, since nothing in `redraw_all()`'s normal `a=p`/`a=d` toggling
ever re-transmits. `redraw_all()` now checks, for each handle it finds
visible, whether `caps.terminal == "ghostty"` and that handle's own cache
entry's recorded `vim.o.lines`/`vim.o.columns` differs from the current
values (the exact same signal `acquire_idle_entry` uses above, just read
instead of also gating reuse — see `ghostty_entry_stale()` in
`renderer.lua`).

Two things confirmed via manual testing on a real Ghostty window shaped
this path beyond a naive "re-`a=T`, same id" attempt:

- **Re-transmitting under the same id does not work.** Ghostty apparently
  will not restore a placement by re-`a=T`-ing under an id it already
  discarded the data for, even though the write itself reports success
  (`q=2` suppresses all responses, so blit has no way to detect this other
  than the empirical result). `retransmit_and_place()` therefore frees the
  stale id and hands the handle a *fresh* one via `alloc_id()`, exactly
  mirroring how `acquire_idle_entry` above already treats a stale idle
  entry (free the old id, never reuse it) — it just also updates the
  now-live handle's `id` field and cache entry in place rather than
  waiting for a future `show()` call to do so.
- **A real drag-resize gesture fires many intermediate `WinResized`
  events, not just one at the final size** (observed: 6 within under a
  second for a single, quick drag). Retransmitting on every one of those,
  back to back, made Ghostty's own recovery unreliable — the image came
  back on some redraw passes and not others. So the retransmit itself is
  not done inline in `redraw_all()`; detecting staleness there only
  (re)starts a separate, short-lived timer (`M._ghostty_settle_ms`, 100ms,
  tuned via repeated manual testing) via `schedule_ghostty_retransmit()`.
  Only once that timer actually fires — meaning no further `WinResized`
  restarted it in the meantime — does `ghostty_retransmit_pass()` re-check
  every handle and retransmit whichever are still stale. The cheap
  `a=p`/`a=d` reposition/hide in `redraw_all()`'s normal per-pass loop
  keeps running unthrottled throughout the drag, same as ever; only the
  expensive retransmit is deferred.

This is a deliberate, narrow exception to AGENTS.md's "never re-transmit
pixel data on scroll/resize" performance rule: the settle timer only ever
gets (re)started when `ghostty_entry_stale()` comes back true, which only
happens right after a genuine resize (scroll-only redraw passes never flip
it), so the cost is bounded to roughly once per real Ghostty resize
gesture per visible handle — see AGENTS.md's Performance Rules section for
the carved-out wording. Kitty and WezTerm are unaffected:
`ghostty_entry_stale()` short-circuits to `false` for any other terminal,
so their redraw path is unchanged, and the settle timer is never even
created for them. Like `debounce_timer`, `ghostty_retransmit_timer` is
stopped and closed by `maybe_teardown_autocmds()` once zero handles remain,
preserving the "no timers active when zero images are displayed" rule.

## Lifecycle

Two distinct kinds of state transition, kept separate:

- **Redraw** (`WinScrolled`, `WinResized`, `TabEnter`, `TabLeave`, debounced
  by `config.debounce_ms` — single deferred recompute per burst, per
  AGENTS.md's performance rule):
  recomputes visibility/position/crop for every still-anchored handle
  (`compute_placement` returns a single `blit.PlacementResult` struct
  carrying the target screen row/col, the — possibly clipped — target cell
  size, and any crop keys, or `nil` if nothing is visible) and toggles its
  placement (`a=p` to show/reposition, `a=d` to hide). Never destroys a
  handle, and never transmits itself — the narrow Ghostty resize
  self-heal described in "Transmission cache" above only ever gets
  (re)armed here (`ghostty_entry_stale()` gates it to a confirmed Ghostty
  resize) and actually retransmits later, on its own separately-debounced
  settle timer; every other terminal and every scroll-only pass stays
  reposition/hide-only throughout. `M.show()` also triggers this same
  debounced pass at the end of a successful call whenever more than one
  handle exists, since its new `virt_lines` reservation can shift where
  sibling handles now render (issue #18) — see "Forcing a redraw before the
  first placement" above.

  **`a=d` is reissued on every pass a handle is invisible, not just the
  transition into invisibility.** A successful `M._write_fn()` call for a
  hide only confirms the delete bytes reached the tty, not that the
  terminal actually erased the placement on screen — on WezTerm, the
  documented scroll-driven rendering lag (`docs/spec/kitty-graphics.md`'s
  Per-terminal quirks) can leave clipped pixels stuck on screen past the
  window's edge indefinitely, because nothing else ever revisits an
  already-`handle.visible = false` handle to retry the delete (issue #23).
  `redraw_all()` therefore reissues `a=d` unconditionally whenever
  `compute_placement` reports invisible, mirroring how the visible branch
  already reissues `a=p` every pass regardless of prior state. This is
  self-healing rather than a root-cause fix for WezTerm's lag — blit cannot
  detect whether a given `a=d` actually took effect (`q=2` suppresses all
  terminal responses, see `docs/spec/kitty-graphics.md`'s "Response
  handling") — but it's cheap (escape-sequence bytes only, no pixel
  payload) and bounded by the same debounce as everything else in this
  pass, so a later scroll settling always gets one more chance to clear a
  stuck placement.
- **Destroy** (`BufWinLeave` for the specific `(buf, win)` pair,
  `WinClosed` for a closing window, `BufWipeout` for a wiped buffer,
  `M.clear()`/`M.clear_all()`, and `VimLeavePre`): removes the extmark,
  removes the handle from `M._handles`, marks its cache entry idle, and
  deletes its terminal-side placement. Only `VimLeavePre` (and
  `M.clear`/`M.clear_all`'s eventual full-teardown path) also frees the
  id back to the pool and the terminal's stored pixel data
  (`d=I`) — everyday `clear()` keeps the cache warm.

  **`a=d` is retried a bounded number of times after destroy too, not just
  on the redraw path above.** Unlike a still-tracked invisible handle, a
  destroyed handle leaves `M._handles` for good — so if its `a=d` is the one
  WezTerm drops, there is no future `redraw_all()` pass left that would ever
  revisit it, and no guarantee a `WinScrolled`/`WinResized` event even fires
  again afterward to trigger one (issue #27; the repro is `clear_all()`
  followed by *no* further input at all). `destroy_handle`'s `free_data =
  false` path (the everyday teardown reasons above, not `VimLeavePre`)
  therefore queues its id onto a small self-scheduled retry list
  (`DESTROY_DELETE_RETRIES`, currently 3 extra attempts) that rides the same
  debounce timer as `redraw_all`, resending a plain `a=d` each pass until
  the budget runs out. Bounded, unlike the redraw path's resend-indefinitely
  behavior, so a terminal that never honors the delete can't keep the
  debounce timer (and therefore the "fully quiescent idle" guarantee) alive
  forever. `VimLeavePre`'s `free_data = true` path is excluded: it frees the
  id immediately, and Neovim is exiting right after, so a queued retry has
  nothing meaningful left to protect and only risks racing a reused id
  against a process that's already gone. If `acquire_idle_entry` reclaims a
  still-queued id for a fresh placement before its retries are spent, the
  queued entry is cancelled — otherwise a late retry could send `a=d` for an
  id a brand new placement now legitimately owns.

All autocmds live in one `augroup("blit", { clear = true })`; all extmarks in
one `nvim_create_namespace("blit")`, both created lazily on first `show()`
(zero-cost `require`/`setup()`, per AGENTS.md). Once the last handle is
destroyed *and* no destroy-path retry is still outstanding (see above), the
debounce timer is stopped/closed and the augroup is deleted — fully
quiescent idle, no dangling autocmds or timers, until the next `show()`
recreates them. A bounded window of up to `DESTROY_DELETE_RETRIES` extra
passes can elapse between "last handle destroyed" and that quiescent state
if a retry is in flight.
