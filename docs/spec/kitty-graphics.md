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
| `p` | placement id | always `1` (blit's single fixed placement id — see "Placement" below) |
| `c`, `r` | placement columns/rows | caller-supplied, cell-fit dimensions |
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

- `a=p,i=<id>,p=1` redisplays an already-transmitted image without resending
  pixel data. This is how blit satisfies the performance rule that
  scroll/resize redraws must reuse the existing id rather than
  re-transmitting.
- `p=1` (blit's fixed placement id, `terminal.PLACEMENT_ID`) is **always**
  sent, on every placement command — both the initial `a=T` transmit+display
  and every later `a=p` reposition. If `p=` is omitted, the terminal creates
  a brand-new placement on every call instead of moving the existing one;
  since blit repositions on every debounced `WinScrolled`/`WinResized`
  redraw, this silently accumulates stacked "ghost" placements at each prior
  screen position — visible as partial/duplicated image fragments while
  scrolling, until a `a=d,d=i` delete (see below) clears all of them at
  once. Reusing the same `i=` **and** `p=` pair on every call makes each
  `a=p` update that one placement in place instead. blit never needs more
  than one placement id per image id: `renderer.lua`'s cache only ever marks
  a given image id "active" for a single handle at a time, so a constant
  `p=1` can never collide with a second live placement of the same id.
- Optional placement keys, in the fixed order blit emits them: `p=` (always
  present when placing), `c=`, `r=`, `z=`, `C=1` (only present if requested).

## Deletion

- `a=d,d=i,i=<id>` deletes the visible placement(s) for one image id blit
  owns; `d=I` additionally frees the terminal's stored pixel data for that id.
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
