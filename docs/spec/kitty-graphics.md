# Kitty Graphics Protocol — blit.nvim usage subset

This memo documents the subset of the [kitty graphics
protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) that blit
implements. Per `AGENTS.md`'s Spec Memo Workflow, implementation code must
cite this memo, not the upstream docs directly. If reality diverges from
this memo, fix the memo in the same PR as the code change.

## Escape sequence framing

Every command is an APC (Application Program Command) escape sequence:

```
\x1b_G<control-data>;<payload>\x1b\\
```

- `\x1b_G` starts the command.
- `<control-data>` is a comma-separated list of `key=value` pairs.
- `<payload>` (optional, base64-encoded) follows a literal `;`.
- `\x1b\\` (ST, String Terminator) ends the command.

## Control data keys blit uses

| Key | Meaning | Values blit emits |
|---|---|---|
| `a` | action | `T` (transmit+display), `t` (transmit only), `p` (display existing), `d` (delete) |
| `f` | pixel format | `100` (PNG) — only format blit ever sends, per the PNG-only v0.x constraint |
| `t` | transmission medium | `d` (direct, i.e. the payload is in the escape code itself) — blit never uses file-based (`t=f`) or shared-memory transmission, to avoid any filesystem/IPC surface beyond reading the source PNG |
| `i` | image id | one of blit's reserved range, see below |
| `q` | quiet | `2` (suppress all responses) always, see "Response handling" below |
| `m` | more chunks | `1` (more chunks follow) / `0` (last chunk) |
| `p` | placement id | a per-handle id, distinct across every concurrently-live placement — see "Placement" below |
| `c`, `r` | placement columns/rows | shrink to the visible cell span when a placement is partially clipped, see "Source-rectangle cropping" below |
| `x`, `y` | source rectangle pixel offset (left/top) into the transmitted image | present only when a placement is partially clipped; see "Source-rectangle cropping" below |
| `w`, `h` | source rectangle pixel size | present only when a placement is partially clipped; see "Source-rectangle cropping" below |
| `z` | z-index | caller-supplied |
| `C` | cursor movement | `1` (don't move cursor) when requested |
| `d` | delete unit (only with `a=d`) | `i` (delete placements for one owned id) or `I` (also free stored pixel data for one owned id) — **never `a`** (delete-all) |

## Transmission

- Format is always `f=100` (PNG); the kitty terminal decodes PNG natively, so
  blit never decodes pixel data itself.
- Medium is always `t=d` (direct/inline). The full PNG file is base64-encoded
  and split into chunks of at most **4096 bytes of base64 text** each.
- The **first** chunk's control data carries every key needed for the
  transmission (`a`, `f`, `t`, `i`, `q`, plus `m` if more chunks follow).
- **Every subsequent chunk's control data carries only the `m` key** — no
  other key is repeated. This matches the upstream protocol's chunking
  examples and keeps escape codes minimal.
- The last chunk has `m=0` (explicit, not omitted — this is what
  `terminal.lua`'s golden-string tests assert byte-exactly).

## Placement

- `a=p,i=<id>,p=<placement_id>` redisplays an already-transmitted image
  without resending pixel data. This is how blit satisfies the performance
  rule that scroll/resize redraws must reuse the existing id rather than
  re-transmitting.
- `p=` (a caller-supplied placement id, `blit.terminal.PlacementOpts.placement_id`
  in `terminal.lua`) is **always** sent, on every placement command — both
  the initial `a=T` transmit+display and every later `a=p` reposition. If
  `p=` is omitted, the terminal creates a brand-new placement on every call
  instead of moving the existing one; since blit repositions on every
  debounced `WinScrolled`/`WinResized` redraw, this silently accumulates
  stacked "ghost" placements at each prior screen position — visible as
  partial/duplicated image fragments while scrolling, until a `a=d,d=i`
  delete (see below) clears all of them at once. Reusing the same `i=`
  **and** `p=` pair on every call makes each `a=p` update that one placement
  in place instead.
- **One image id can have several concurrent placements (issue #10,
  "Multi-location placement fan-out").** Earlier versions of blit sent a
  single fixed `p=1` on every call, relying on `renderer.lua`'s cache never
  marking a given image id "active" for more than one handle at a time. That
  constraint is gone: `renderer.lua` now allocates a distinct, never-reused
  placement id per handle (`alloc_placement_id()`, an ever-incrementing
  session-lifetime counter — see `docs/spec/renderer-placement.md`'s
  "Transmission cache" section), so a second `show()` of the same
  `(path, mtime)` while the first is still live reuses the SAME image id
  under a DIFFERENT placement id — a second, independent placement — instead
  of transmitting a redundant copy under a new image id. Each placement is
  then addressed, repositioned, and torn down independently by its own
  `(id, placement_id)` pair.
- Optional placement keys, in the fixed order blit emits them: `p=` (always
  present when placing), `x=`, `y=`, `w=`, `h=` (source rectangle, only when
  cropped — see "Source-rectangle cropping" below), `c=`, `r=` (target cell
  box), `z=`, `C=1` (only present if requested).

## Source-rectangle cropping

kitty's placement command accepts a source rectangle (`x`, `y`, `w`, `h`, all
pixel values into the previously transmitted image) alongside the target cell
box (`c`, `r`). blit uses this to show a partially-visible placement as a
cropped slice rather than hiding it entirely — see
`docs/spec/renderer-placement.md`'s "Visibility policy" for the row/column
clip-amount math (`compute_clip`) and the pixel-space conversion
(`pixel_crop`), both in `lua/blit/renderer.lua`.

- `x`/`y` are the pixel offset of the crop's top-left corner within the
  transmitted image; `w`/`h` are its pixel size. All four are computed
  proportionally from how many cell rows/columns of the placement's original
  target span are clipped on each side, against the image's *native* pixel
  dimensions (read once via `lua/blit/png.lua`'s IHDR reader — metadata only,
  never a full PNG decode; this doesn't touch the PNG-only/zero-dependency
  constraints since no pixel data is ever read by blit itself).
- Keys are emitted in clipped **axis pairs**, independently per axis: `x=`
  and `w=` together only when the column axis is clipped, `y=` and `h=`
  together only when the row axis is clipped. A single-axis clip (e.g. only
  rows clipped) omits the other axis's pair entirely rather than sending all
  four — an unclipped placement omits all four (zero escape-sequence byte
  cost in the common case). `x=0`/`y=0` are legitimate, explicitly-sent
  values (e.g. only the far edge of a placement is clipped) — blit checks
  for a non-nil value (`if opts.crop_x then` — Lua's `0` is truthy, so this
  correctly still emits `x=0`), not `> 0`, so a genuine `0` offset is never
  dropped.
- **Assumed, pending manual verification** (see `docs/manual-testing.md`):
  omitting one axis's pair (`x=`/`w=` or `y=`/`h=`) while sending the
  other's is expected to make the terminal default the omitted axis to the
  full, unclipped image span (offset `0`, size = native width/height) —
  i.e. kitty/WezTerm/Ghostty fill in the missing `x`/`w` (or `y`/`h`) as if
  the whole image were requested on that axis, rather than leaving it at a
  stale or zero size. Unverified on a real terminal as of this writing (only
  exercised in headless Neovim, which never talks to a real terminal). If a
  real terminal instead defaults an omitted axis to something other than
  the full image span, the fix is to always emit all four keys explicitly
  once any axis is clipped (defaulting the unclipped axis's `x`/`y` to `0`
  and `w`/`h` to `native_width`/`native_height`) — a small, contained change
  to `compute_placement`/`placement_opts` in `lua/blit/renderer.lua`, not a
  redesign.
- `c=`/`r=` shrink to the visible cell span (not the placement's original
  full `width`/`height`) whenever the corresponding axis is cropped, so the
  cropped slice renders at the correct on-screen size instead of being
  stretched to fill the original box.
- **Assumed, pending manual verification** (see `docs/manual-testing.md`):
  re-issuing `a=p` with no `x=`/`y=`/`w=`/`h=` at all (the placement having
  previously been cropped, now fully back in view) is expected to reset the
  placement to showing the complete, uncropped image — i.e. the terminal
  does not remember a prior call's crop rectangle across placement commands,
  the same way `c=`/`r=`/`z=` are already treated as fully-specified-per-call
  rather than incrementally patched. Unverified on a real kitty/WezTerm/
  Ghostty terminal as of this writing (only exercised in headless Neovim,
  which never talks to a real terminal). If a real terminal instead retains
  the last explicit crop rectangle, the fix is to always emit the full
  rectangle explicitly (`x=0,y=0,w=native_width,h=native_height`) once a
  handle has ever been cropped, rather than omitting it — a small, contained
  change to `placement_opts` in `lua/blit/renderer.lua`, not a redesign.
- This only affects `a=p`/`a=T`'s placement sub-table; it never causes a
  re-transmit (`a=T` with fresh pixel data) on its own — `renderer.lua`'s
  `redraw_all` still only ever repositions (`a=p`) or hides (`a=d`) on a
  scroll/resize-driven redraw pass, satisfying AGENTS.md's "never re-transmit
  on scroll/resize" rule (the pre-existing, narrow Ghostty resize exception
  is unrelated to cropping).

## Deletion

- `a=d,d=i,i=<id>` deletes the visible placement(s) for one image id blit
  owns; `d=I` additionally frees the terminal's stored pixel data for that id.
- `p=<placement_id>`, when supplied alongside `d=i`, restricts the delete to
  that ONE placement of the id rather than every placement blit has made for
  it — required now that one id can have several concurrent placements (see
  "Placement" above). `renderer.lua` always includes it except for the
  whole-id teardown case: freeing a handle's placement while the id might
  still be shared by a sibling handle (`terminal.build_delete(id, {
  placement_id = ... })`), vs. freeing the id's stored data entirely once no
  handle references it anymore (`terminal.build_delete(id, { free_data =
  true })`, no `p=`, since every placement is being torn down together at
  that point anyway) — see `docs/spec/renderer-placement.md`'s Lifecycle
  section for the full decision.
- blit **never** emits `d=a` (delete every image on the terminal, including
  ones placed by other plugins like image.nvim/snacks.image). Every deletion
  path in `terminal.lua` is scoped to a single caller-supplied id.

## Unicode placeholders

The protocol also supports a Unicode-placeholder-based placement mode
(drawing images via a special Unicode codepoint region plus diacritics
encoding row/column/image-id). blit does not use this in v0.x — it exists
for terminal-multiplexer/scrollback-friendly placement, which is out of
scope while tmux is explicitly unsupported. Documented here so a future v2
revisiting tmux support doesn't have to rediscover this from scratch.

## Reserved image ID range

```
ID_RANGE_START = 0x626C0000  (1,651,245,056)
ID_RANGE_END   = 0x626CFFFF  (1,651,310,591)
```

The top 16 bits (`0x626C`) spell the ASCII bytes `b`, `l` — a self-describing
"blit" namespace. The kitty image id space (1..4294967295) is shared
terminal-wide with other plugins. Plugins like image.nvim and snacks.image
tend to hand out small sequential integers starting near 1; blit's range
sits far above that and occupies only ~1.5×10⁻⁵ of the id space, making
collision negligible while still allowing 65,536 concurrent ids. `terminal.lua`
exposes `ID_RANGE_START` / `ID_RANGE_END` / `is_valid_id()` as protocol-level
facts; the stateful counter that actually hands out ids from this range is
`renderer.lua`'s responsibility (it owns the handle table), not
`terminal.lua`'s.

## Response handling

blit always sets `q=2` (suppress all responses — no `OK` and no error
response is sent back by the terminal). This is a deliberate v0.x
limitation: blit does not read stdin asynchronously to parse protocol
responses, so any response bytes that did arrive would otherwise leak into
Neovim's normal input stream. The consequence is that blit cannot currently
detect terminal-side transmission errors (e.g. malformed PNG rejected by the
terminal) — failures are only visible if they cause a visible rendering
problem. Revisiting this (async stdin reader surfacing errors through
`:checkhealth` or return values) is a future-version consideration, not
implemented speculatively here.

## Per-terminal quirks

- **kitty**: the protocol's reference implementation; full support for
  everything in this memo.
- **WezTerm**: does not support Unicode placeholders (irrelevant to blit
  since it doesn't use them). Has a known lag re-rendering images during
  fast scrolling — motivates the debounced-redraw performance rule in
  `AGENTS.md`, not something blit's escape-sequence layer works around
  directly.
- **Ghostty**: assumed spec-compliant for the subset above; least
  battle-tested of the three supported terminals. `docs/manual-testing.md`
  should weight Ghostty checks accordingly before any release.

## Source

This memo is derived from the upstream [kitty graphics protocol
documentation](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
Implementation code cites this memo; it should not need to re-read the
upstream docs for anything already covered above.
