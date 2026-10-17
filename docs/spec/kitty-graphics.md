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
| `q` | quiet | when responses can be received: `1` (suppress `OK`, keep errors) on transmits (`a=T`/`a=t`) and standalone placements (`a=p`). Otherwise `2` (suppress everything) on transmits and no `q` key on placements. Never on deletes — see "Response handling" below |
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
  Upstream also requires every chunk except the last to have a size that is
  a multiple of 4; 4096 satisfies that, and so must any other chunk size
  passed to `chunk_base64`.
- The **first** chunk's control data carries every key needed for the
  transmission (`a`, `f`, `t`, `i`, `q`, plus `m`).
- **Every subsequent chunk's control data carries only the `m` key** — no
  other key is repeated. This matches the upstream protocol's chunking
  examples and keeps escape codes minimal.
- The last chunk has `m=0` (explicit, not omitted — this is what
  `terminal.lua`'s golden-string tests assert byte-exactly).
- Transmitting data for an id that already exists replaces that image: the
  terminal deletes the existing image and all of its placements, and the new
  data is not displayed until a placement is created for it.
- The terminal keeps image data under a storage quota (320MB per buffer in
  kitty). When a new image would exceed it, older images are deleted, and
  images without any placement go first. An id blit still holds in its cache
  with no live placement can therefore lose its data on the terminal side;
  a later `a=p` against it is answered with `ENOENT` (see "Response
  handling" below) and draws nothing.

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
- Omitting one axis's pair (`x=`/`w=` or `y=`/`h=`) while sending the
  other's leaves the omitted axis at the full image span: upstream defaults
  `x`/`y` to `0` and `w`/`h` to the whole width/height. `make e2e`
  (`docs/manual-testing.md`, "Automated checks") checks single-axis crops at
  the top, bottom and right edges on kitty, WezTerm and Ghostty.
- `c=`/`r=` shrink to the visible cell span (not the placement's original
  full `width`/`height`) whenever the corresponding axis is cropped, so the
  cropped slice renders at the correct on-screen size instead of being
  stretched to fill the original box.
- With both `c=` and `r=` given (blit always sends both), the source
  rectangle is scaled to fill the cell box on each axis independently, with
  no aspect-ratio correction: a `width`/`height` that does not match the
  image's aspect ratio stretches it. Read from source, not from the upstream
  docs: kitty 0.48.2 through 0.49.2 (`grman_update_layers` in
  `kitty/graphics.c`), Ghostty 1.3.1 (`Placement.calculatedSize` in
  `src/terminal/kitty/graphics_storage.zig`) and WezTerm main
  (`assign_image_to_cells` in `term/src/terminalstate/image.rs`). The
  upstream docs say (since kitty-docs 05444e9e61, 2026-08-23) that an image
  with both keys is letterboxed/pillarboxed; in kitty that code path exists
  only for Unicode-placeholder (`U=1`) placements, which blit does not use
  (see "Unicode placeholders" below). The sentence is worded generally, so
  `/spec-check` should re-check this whenever the `nr`/`nc` branch of
  `grman_update_layers` changes; `docs/manual-testing.md` has a step for it.
  Observed on kitty 0.49.2: a square PNG shown with `width = 40, height = 4`
  fills the whole 40x4 box, with no bars.
- Re-issuing `a=p` with no `x=`/`y=`/`w=`/`h=` at all (the placement having
  previously been cropped, now fully back in view) shows the complete,
  uncropped image again: a placement sent with the same image id and
  placement id replaces the earlier one as a whole, so no crop rectangle
  carries over. `make e2e` checks this ("uncrop after scrolling back") on
  kitty, WezTerm and Ghostty.
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

Placeholder placements also size differently: with both `c` and `r` they
fit the image into the box with its aspect ratio preserved, whereas the
cursor-positioned placements blit uses fill the box (see
"Source-rectangle cropping" above).

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

The terminal answers a graphics command that carries an `i=` with an APC
of its own: `ESC _ G i=<id>[,p=<placement id>] ; <message> ESC \`, where
`<message>` is `OK` or `<CODE>:<text>` (e.g. `EBADPNG:...`, `ENOENT:...`).
The `q` key controls which of these are sent: `q=1` suppresses `OK`, `q=2`
suppresses errors too.

blit never reads stdin itself — Neovim's TUI owns it, and a second reader
would race it for input bytes. The only safe channel is Neovim's own
`TermResponse` event, which delivers APC responses from Neovim 0.12 onward
(0.10/0.11 deliver OSC/DCS only). The sequence arrives as
`ESC _ G <control> ; <message>` with the terminating ST already stripped.
`terminal.has_response_support()` reports whether that channel exists, and
`terminal.parse_response()` decodes one sequence, returning nil for
anything that is not a graphics response about an id in blit's reserved
range.

- **Neovim >= 0.12**: transmits carry `q=1`, so only error responses come
  back. `renderer.lua` records them (see
  `docs/spec/renderer-placement.md`'s "Terminal error responses") and
  `:checkhealth blit` lists them.
- **Neovim 0.10 / 0.11**: transmits carry `q=2`, exactly as before; a
  terminal-side transmission error stays invisible unless it shows up as a
  rendering problem.

Standalone placement (`a=p`) commands follow the same split, with one
difference on old versions:

- **Neovim >= 0.12**: `a=p` carries `q=1`. Without it the terminal may
  acknowledge every re-placement with an `OK`, i.e. one `TermResponse`
  (for blit's listener and every other plugin's) per re-placed handle on
  every redraw pass, only to be discarded. Error answers still come back
  and the same listener records them, which surfaces e.g. an `ENOENT` for
  a placement against an id whose pixel data the terminal has dropped.
- **Neovim 0.10 / 0.11**: `a=p` carries no `q` key, so the terminal's
  default applies and it may answer with `OK` or an error. These bytes
  have always been emitted this way, and no answer has been observed
  leaking into Neovim's input as keystrokes (`docs/manual-testing.md`
  checks this).

Delete (`a=d`) commands carry no `q` key on any version.

`has_response_support()` is a version check (`has("nvim-0.12")`), so it
assumes a released 0.12.0 or later; 0.12 pre-release builds that predate
the APC `TermResponse` support are not accounted for.

Responses are diagnostic only. They arrive asynchronously, after `show()`
has returned, so they cannot become a `nil, err` return value, and no
recovery path (Ghostty retransmit, delete retries) waits on or reacts to
them.

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

Error responses under `q=1`, observed on Neovim 0.12.5 by transmitting a
PNG with a valid signature and IHDR but a corrupt IDAT (`a=T`), then
letting the next redraw pass re-place it (`a=p`):

| terminal | answer to the transmit | answer to the later `a=p` |
|---|---|---|
| kitty 0.48.2, 0.49.2 | `EBADPNG:IDAT: incorrect header check` | `ENOENT:Put command refers to image with id: <id> that could not load its data` |
| Ghostty 1.3.1 | `EINVAL: invalid data` | `ENOENT: image not found` |
| WezTerm 20260716-195552-76b606ec | none | none |

So the error code and text are terminal-specific (blit records the message
verbatim and never matches on it), and WezTerm reports nothing for this
case: on WezTerm a rejected PNG stays invisible to `:checkhealth blit`,
exactly as on Neovim 0.10 / 0.11. On all three, show + scroll + split
with a valid PNG produced no response at all (no `OK` under `q=1`, no
error) and nothing leaked into Neovim's input.

## Source

This memo is derived from the upstream [kitty graphics protocol
documentation](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
Implementation code cites this memo; it should not need to re-read the
upstream docs for anything already covered above.

Pins for `/spec-check` (what upstream looked like when this memo was last
compared against it):

- Last verified: 2026-10-12
- kitty-docs: 87ab3e98f4 / kitty: f78106e296 / wezterm: 6c7e3722b1 / ghostty: 1de05f1a78
