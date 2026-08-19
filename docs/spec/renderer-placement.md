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
(1-indexed) with the resolved `height` (see below) of empty `virt_lines`
attached. The anchor buffer line itself is left untouched (e.g. a markdown
`![alt](path)` line stays intact); the image renders into the reserved
blank lines immediately below it. `opts.width`/`opts.height` are cell
counts (columns/rows); at least one is required, but not both — blit reads
the PNG's *native pixel* dimensions (`lua/blit/png.lua`'s IHDR reader) both
to support cropping a partially-visible placement (see "Visibility policy"
below) and, when the caller omits one of `width`/`height`,
`resolve_cell_size` derives it from the other under an assumed cell aspect
ratio (`opts.cell_aspect_ratio`, defaulting to `config.defaults.cell_aspect_ratio`
= 0.5 — a typical monospace terminal cell's width-px/height-px ratio). This
is only ever an approximation: blit still does not query the terminal's
real cell-pixel size (that would require reading an async protocol
response, out of scope per `docs/spec/kitty-graphics.md`'s "Response
handling" section), so a caller on an unusually wide or narrow font gets a
slightly off aspect ratio unless it supplies both dimensions itself. When
the caller supplies both, they pass through unvalidated — blit never
overrides an intentional stretch/fit. One handle = one entry in
`M._handles`, shaped `{ id, buf, win, extmark_id, path, cache_key, geometry,
z_index, visible, native_width, native_height }`, matching `AGENTS.md`'s
"one image = one handle table" rule.

**Known limitation, narrower since issue #10**: a handle is still bound to
exactly one `win` at creation time, but the `virt_lines` extmark carrying
its reserved blank rows is buffer-scoped, not window-scoped — Neovim
renders those reserved rows in *every* window currently showing that
buffer. If the same buffer is split into a second window
(`:split`/`:vsplit`), the non-anchor window displays the reserved blank
space with no image in it, for as long as it stays open —
`compute_placement` only ever computes visibility/position against the one
`handle.win` it was given. Issue #10 ("Multi-location placement fan-out for
a single transmitted image") added the underlying primitive this needs — a
distinct `p=` per placement, so the same transmitted image id can carry a
second, independent placement without re-transmitting (see "Transmission
cache" below) — but it does not by itself detect a `:split` and create that
second placement automatically: `M.show()` still only ever creates one
handle bound to one `win` per call. A caller can work around the split case
today by calling `M.show()` a second time for the second window explicitly
(same `path`, so the same `(path, mtime)` cache key) — that second call now
fans out onto the first's image id instead of re-transmitting, per issue
#10 — but automatic per-window fan-out for a single `show()` call remains
unimplemented. Accepted for v0.x.

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

## Transmission cache: (path, mtime) keyed, with placement-id fan-out

Cache key: `path .. ":" .. mtime.sec .. "." .. mtime.nsec` (from
`vim.uv.fs_stat`). Each cache entry is a **list** of `{ id,
active_placements, lines, columns, native_width, native_height }` entries
for that exact file content — a list, not a single entry, because a given
key can transiently have both an idle entry and a stale-but-still-active
one (e.g. mid-Ghostty-resize-recovery, see below) even though the common
case settles to exactly one entry per key:

`native_width`/`native_height` (the PNG's native pixel dimensions, read once
via `lua/blit/png.lua`'s IHDR reader when the file is actually read for
transmission) are populated at `register_cache_entry` time and copied onto
every handle that reuses the entry — a cache hit never re-reads or
re-parses the file. These are used solely by `pixel_crop` (see "Visibility
policy" above), never for auto-sizing.

`active_placements` counts how many currently-live handles reference this
entry's id — 0 means idle. `show()`'s `find_reusable_entry` tries an idle
entry first (see the Ghostty exception below), and only if none exists
falls back to any entry with `active_placements > 0`:

- **Idle reuse**: no re-transmission, just an `a=p` placement (or nothing
  yet, if not currently visible) — this is the AGENTS.md performance rule
  ("re-placement... must reuse its ID — never re-transmit").
- **Active reuse, i.e. fan-out (issue #10, "Multi-location placement
  fan-out for a single transmitted image")**: also no re-transmission.
  Earlier versions of blit always sent a single fixed placement id
  (`terminal.PLACEMENT_ID = 1`) and therefore could give a given image id
  only one live placement at a time — a second concurrent `show()` of the
  same file had to transmit a redundant copy under a brand-new id. Every
  real placement command now carries a distinct, caller-allocated
  `placement_id` (`alloc_placement_id()`, defined right below "Placement id
  allocation" — an ever-incrementing, never-reused, session-lifetime
  counter, since placement ids only need to be unique within one image id,
  not terminal-wide the way image ids do) — see `docs/spec/kitty-graphics.md`'s
  Placement section — so a second `show()` of an already-active entry
  instead adds a second, independent placement of the SAME id: `id`
  unchanged, `entry.active_placements` incremented, a fresh
  `handle.placement_id` allocated, and only an `a=p` (or nothing, if not yet
  visible) written — matching the idle-reuse case exactly except that the
  entry was never idle to begin with.

`destroy_handle` (see "Lifecycle" below) is the inverse: it decrements
`active_placements` and deletes only this handle's own placement
(`a=d,d=i,i=<id>,p=<placement_id>`) — a sibling placement sharing the same
id, if any, is untouched. The terminal-side pixel data itself is only ever
freed (`d=I`, no `p=`) once `active_placements` reaches `0` **and** the
caller's intent was to free it (`VimLeavePre`'s full teardown, or a fatal
failure right after `M.show()` created the handle) — an everyday
`clear()`/`clear_all()` never frees data even when it drops the count to
`0`, keeping the entry idle-but-warm for a future `show()` instead.

Cache entries are otherwise never evicted except at `VimLeavePre` (or the
test-only `_reset()`) — an idle entry's id and terminal-side pixel data are
kept around so a later `show()` of the same file is cheap. **Known
limitation**: this means the id pool (65,536 ids,
`docs/spec/kitty-graphics.md`'s reserved range) is not reclaimed during a
long session that `show()`s many distinct files; unbounded growth is
accepted for v0.x (mirrors that memo's own acceptance of the range being
merely "negligible collision risk", not infinite). `alloc_id()` returns
`nil, err` if the range is exhausted; `show()` propagates that as a normal
`nil, err_msg` failure. Placement ids draw from the full unsigned 32-bit
`p=` space rather than a bounded pool (see "Placement id allocation" in
`renderer.lua`), so they have no equivalent exhaustion case in practice.

**Ghostty exception: idle entries recorded against a stale terminal size
are evicted eagerly, at reuse time.** Ghostty discards previously-
transmitted image data behind an id across a real terminal window resize,
silently — there is no error response to detect it by (`q=2` suppresses
all responses, `docs/spec/kitty-graphics.md`'s "Response handling"), and
`:checkhealth blit` still reports the terminal as supported. Reusing such
an id for a placement-only `a=p` then renders nothing (issue #24). Each
cache entry therefore also records `vim.o.lines`/`vim.o.columns` (the whole
Neovim grid size, which tracks the real terminal's size — not a per-window
size) at the moment of transmission. `find_reusable_entry` compares an idle
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
`find_reusable_entry` call. **Accepted false negative**: if the terminal is
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
values (the exact same signal `find_reusable_entry` uses above, just read
instead of also gating reuse — see `ghostty_entry_stale()` in
`renderer.lua`).

Two things confirmed via manual testing on a real Ghostty window shaped
this path beyond a naive "re-`a=T`, same id" attempt:

- **Re-transmitting under the same id does not work.** Ghostty apparently
  will not restore a placement by re-`a=T`-ing under an id it already
  discarded the data for, even though the write itself reports success
  (`q=2` suppresses all responses, so blit has no way to detect this other
  than the empirical result). `retransmit_and_place_group()` therefore frees the
  stale id and hands every handle sharing it a *fresh* one via `alloc_id()`,
  exactly mirroring how `find_reusable_entry` above already treats a stale idle
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
the carved-out wording.

**A settle-timer pass that leaves a handle still stale gets a bounded
number of retries of its own (issue #37).** `ghostty_retransmit_pass()` can
find a handle still `ghostty_entry_stale()` after it runs even though no
further `WinResized`/`WinScrolled` restarted the timer: `compute_placement()`
can come back `nil` for that one tick (a real drag-resize's tail end can
still race `vim.fn.screenpos()`), or `retransmit_and_place_group()`'s write itself
can fail (`write_all()` exhausting its bounded EAGAIN retries — see
`terminal.lua`). Before this was fixed, either case left the placement
blank until the user happened to trigger another resize purely by luck —
manual testing observed this intermittently on a slow, continuous drag
crossing several cell sizes. `ghostty_retransmit_pass()` now re-arms its own
timer (`arm_ghostty_retransmit_timer()`) up to `GHOSTTY_RETRANSMIT_RETRIES`
(3) additional times whenever a pass ends with any handle still stale,
mirroring `DESTROY_DELETE_RETRIES` above (issue #27) — same shape of
problem, an escape-sequence-driven recovery with no response to confirm
success by. `schedule_ghostty_retransmit()` (the entry point `redraw_all()`
calls on a genuine detection) resets the retry budget back to the max each
time, so a fresh resize gesture always gets the full budget; only the
self-rescheduled retries within a single settle window consume it. Bounded,
not indefinite, so a handle that's genuinely gone (e.g. its window closed)
can't keep the timer alive forever, preserving AGENTS.md's "fully
quiescent idle" rule.

Kitty and WezTerm are unaffected:
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
  removes the handle from `M._handles`, decrements its cache entry's
  `active_placements`, and deletes only THIS handle's own placement
  (`a=d,d=i,i=<id>,p=<placement_id>`) — never the whole id, since a fan-out
  sibling (issue #10) may still hold a live placement on it. Only once
  `active_placements` reaches `0` **and** the caller's intent was to free
  data (`VimLeavePre`'s full teardown, or a fatal failure right after
  `M.show()` created the handle) does `destroy_handle` also free the id back
  to the pool and the terminal's stored pixel data (`d=I`, no `p=`, since
  every placement sharing the id is gone by then) — everyday `clear()` never
  frees data, keeping the entry idle-but-warm instead, regardless of
  whether it just dropped to `0`.

  **`a=d` is retried a bounded number of times after destroy too, not just
  on the redraw path above.** Unlike a still-tracked invisible handle, a
  destroyed handle leaves `M._handles` for good — so if its `a=d` is the one
  WezTerm drops, there is no future `redraw_all()` pass left that would ever
  revisit it, and no guarantee a `WinScrolled`/`WinResized` event even fires
  again afterward to trigger one (issue #27; the repro is `clear_all()`
  followed by *no* further input at all). `destroy_handle`'s everyday-
  teardown path (any call where the caller didn't request a full free, or
  did but a fan-out sibling still shares the id — see above) therefore
  queues its `(id, placement_id)` pair onto a small self-scheduled retry
  list (`DESTROY_DELETE_RETRIES`, currently 3 extra attempts) that rides the
  same debounce timer as `redraw_all`, resending the same scoped `a=d` each
  pass until the budget runs out. Bounded, unlike the redraw path's resend-
  indefinitely behavior, so a terminal that never honors the delete can't
  keep the debounce timer (and therefore the "fully quiescent idle"
  guarantee) alive forever. The full-free branch (id actually freed) is
  always excluded from queuing — nothing else references that id anymore.
  The fan-out-sibling-still-shares-the-id case is excluded from queuing
  only when the caller is truly shutting down (`opts.shutting_down`, set by
  `VimLeavePre` and the test-only `_reset()`): the process (or test run) is
  exiting right after, so a queued retry has nothing meaningful left to
  protect and only risks racing a reused id against a process that's
  already gone. A fatal `M.show()` failure tearing down a fan-out handle
  whose sibling is still live does NOT set `shutting_down` — the process
  keeps running and no future `redraw_all()` pass will ever revisit this
  specific `(id, placement_id)` again once the handle is gone, so it gets
  the same bounded retry as everyday teardown instead (issue #10). If
  `find_reusable_entry` reclaims a still-queued id for a fresh
  placement before its retries are spent, the queued entries for that id
  are cancelled (`cancel_pending_delete`) — though even without that, a late
  retry naming the OLD `placement_id` could never hit the new placement's
  DIFFERENT one, since placement ids are never reused (see "Placement id
  allocation" in `renderer.lua`); the cancellation is belt-and-suspenders
  against wasted escape-sequence bytes, not a correctness requirement.

All autocmds live in one `augroup("blit", { clear = true })`; all extmarks in
one `nvim_create_namespace("blit")`, both created lazily on first `show()`
(zero-cost `require`/`setup()`, per AGENTS.md). Once the last handle is
destroyed *and* no destroy-path retry is still outstanding (see above), the
debounce timer is stopped/closed and the augroup is deleted — fully
quiescent idle, no dangling autocmds or timers, until the next `show()`
recreates them. A bounded window of up to `DESTROY_DELETE_RETRIES` extra
passes can elapse between "last handle destroyed" and that quiescent state
if a retry is in flight.
