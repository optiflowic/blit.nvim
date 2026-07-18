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
columns }` entries for that exact file content — a list, not a single
entry, because:

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

Out of scope for this mitigation: a handle that stays visible/active
across a Ghostty resize (never cleared) is not covered — issue #24's own
repro clears the handle before resizing, and pre-emptively re-transmitting
every currently-displayed image on every resize (to also cover that case)
was judged too costly to take on speculatively without a report confirming
it actually happens.

## Lifecycle

Two distinct kinds of state transition, kept separate:

- **Redraw** (`WinScrolled`, `WinResized`, `TabEnter`, `TabLeave`, debounced
  by `config.debounce_ms` — single deferred recompute per burst, per
  AGENTS.md's performance rule):
  recomputes visibility/position for every still-anchored handle and
  toggles its placement (`a=p` to show/reposition, `a=d` to hide). Never
  transmits, never destroys a handle. `M.show()` also triggers this same
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
