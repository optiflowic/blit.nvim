#!/usr/bin/env bash
# Standalone reproduction for issue #31: WezTerm process crashes (taking the
# Neovim session with it) under sustained fast scrolling with an image shown.
#
# This script contains NO Neovim and NO blit code. It writes the exact same
# escape-sequence bytes blit's renderer/terminal layers emit on a scroll-driven
# redraw pass directly to the tty in a tight loop, for a long duration, at a
# rate matching sustained held-key scroll repeat (see AGENTS.md's terminal
# layer notes and lua/blit/terminal.lua's build_transmit/build_placement).
#
# Root cause (confirmed via a real WezTerm crash log, see issue #31 for the
# full investigation): WezTerm's renderer allocates a runaway ~10 million
# quads for a single paint pass when a graphics placement is repositioned
# while real on-screen text scrolls within a DECSTBM scroll region (the same
# region Neovim itself sets, excluding tabline/statusline-like chrome). The
# vertex buffer allocation for that fails, and an `.unwrap()` on the failure
# at wezterm-gui/src/termwindow/render/draw.rs:258 panics inside a Cocoa
# `drawRect:` callback -- which can't unwind across that FFI boundary, so
# WezTerm aborts (SIGABRT) and takes the Neovim session down with it. This is
# a WezTerm-side bug (reported upstream), not something fixable from blit's
# escape-sequence content or write pacing.
#
# Usage:
#   ./scripts/repro-31-wezterm-crash.sh
#     Default: scrolls real text within a DECSTBM scroll region while
#     sweeping the placement's row -- the minimal combination confirmed to
#     reproduce the crash.
#
#   BLIT_REPRO_SCROLL_REGION=0 ./scripts/repro-31-wezterm-crash.sh
#     Plain line-feed scrolling of the whole screen instead of a scroll
#     region. Kept for comparison: this variant does NOT reproduce the
#     crash, which is what narrowed the trigger down to the scroll-region
#     code path in the first place.
#
# Run this in a real WezTerm tab (not tmux, not a GUI/embedded terminal).
# It prints a heartbeat line every second to stderr so that if WezTerm's
# process dies mid-run, the last printed timestamp gives an approximate
# time-of-death to correlate against a WezTerm crash log
# (~/Library/Logs/DiagnosticReports/ on macOS, or `wezterm --log-file`).
#
# Env vars (all optional):
#   BLIT_REPRO_RATE_HZ       bursts per second (default: 30, matching the
#                            ~30-40Hz key-repeat rate noted in issue #31)
#   BLIT_REPRO_DURATION_SEC  total run time in seconds (default: 180 --
#                            wraps back to BLIT_REPRO_ROW_START and sweeps
#                            again if it reaches BLIT_REPRO_ROW_END first)
#   BLIT_REPRO_ROW_START     first screen row of the sweep (default: 50,
#                            matching the "anchored ~50 lines down" repro)
#   BLIT_REPRO_ROW_END       last screen row of the sweep (default: 1,
#                            matching "travels to the window's top"); the
#                            row steps by 1 toward this value each burst
#   BLIT_REPRO_COLS          placement width in cells (default: 20)
#   BLIT_REPRO_ROWS          placement height in cells (default: 15)
#   BLIT_REPRO_TEXT_SCROLL   1 to emit real scrolling text alongside each
#                            placement reposition (default: 1); 0 reproduces
#                            the v2 placement-only-sweep behavior
#   BLIT_REPRO_SCROLL_REGION 1 to scroll within a DECSTBM scroll region
#                            (rows 2..LINES-1) instead of plain line-feed
#                            scrolling of the whole screen (default: 0);
#                            implies text scrolling regardless of
#                            BLIT_REPRO_TEXT_SCROLL. When set, ROW_START/
#                            ROW_END default inside the scroll region
#                            instead of the plain-scroll defaults.
#   BLIT_REPRO_TTY           tty path to write to (default: auto-probe
#                            /dev/tty then /dev/fd/1, matching blit's own
#                            fallback in lua/blit/terminal.lua)
#
# A minimal 1x1 transparent PNG is embedded below so this script needs no
# external image file and no ImageMagick/base64-generation dependency.

set -eu

RATE_HZ="${BLIT_REPRO_RATE_HZ:-30}"
DURATION_SEC="${BLIT_REPRO_DURATION_SEC:-180}"
COLS="${BLIT_REPRO_COLS:-20}"
ROWS="${BLIT_REPRO_ROWS:-15}"
TEXT_SCROLL="${BLIT_REPRO_TEXT_SCROLL:-1}"
SCROLL_REGION="${BLIT_REPRO_SCROLL_REGION:-0}"

case "$RATE_HZ" in
  ''|*[!0-9]*)
    echo "BLIT_REPRO_RATE_HZ must be a positive integer (got: '${RATE_HZ}')" >&2
    exit 1
    ;;
esac
if [ "$RATE_HZ" -eq 0 ]; then
  echo "BLIT_REPRO_RATE_HZ must be greater than 0" >&2
  exit 1
fi

if [ "$SCROLL_REGION" = "1" ]; then
  TEXT_SCROLL=1
  LINES_TOTAL=$(tput lines 2>/dev/null || echo 24)
  # Exclude row 1 (tabline-like chrome) and the last row (statusline-like
  # chrome) from the scroll region, mirroring Neovim's usual DECSTBM setup.
  SCROLL_TOP=2
  SCROLL_BOTTOM=$((LINES_TOTAL - 1))
  if [ "$SCROLL_BOTTOM" -le $((SCROLL_TOP + 2)) ]; then
    echo "terminal too short for a scroll-region repro (only ${LINES_TOTAL} rows) -- resize taller" >&2
    exit 1
  fi
  ROW_START="${BLIT_REPRO_ROW_START:-$((SCROLL_BOTTOM - 1))}"
  ROW_END="${BLIT_REPRO_ROW_END:-$((SCROLL_TOP + 1))}"
else
  ROW_START="${BLIT_REPRO_ROW_START:-50}"
  ROW_END="${BLIT_REPRO_ROW_END:-1}"
fi

if [ "$ROW_END" -ge "$ROW_START" ]; then
  ROW_STEP=1
else
  ROW_STEP=-1
fi

# Same reserved id range blit uses (lua/blit/terminal.lua's ID_RANGE), one
# fixed id, one fixed placement id -- matches M.PLACEMENT_ID = 1.
IMAGE_ID=1651802113 # 0x626C0001
PLACEMENT_ID=1

ESC=$'\033'
APC_START="${ESC}_G"
APC_END="${ESC}\\"

# 1x1 transparent PNG, base64-encoded (67 bytes decoded) -- well under the
# 4096-byte chunk size, so this is always a single m=0 chunk.
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

TTY_PATH="${BLIT_REPRO_TTY:-}"
if [ -z "$TTY_PATH" ]; then
  if [ -w /dev/tty ] 2>/dev/null; then
    TTY_PATH=/dev/tty
  else
    TTY_PATH=/dev/fd/1
  fi
fi

if [ "$SCROLL_REGION" = "1" ]; then
  echo "blit #31 repro: writing to ${TTY_PATH}, ${RATE_HZ}Hz for ${DURATION_SEC}s, row sweep ${ROW_START}->${ROW_END} (image ${COLS}x${ROWS} cells), scroll region rows ${SCROLL_TOP}-${SCROLL_BOTTOM} of ${LINES_TOTAL}" >&2
else
  echo "blit #31 repro: writing to ${TTY_PATH}, ${RATE_HZ}Hz for ${DURATION_SEC}s, row sweep ${ROW_START}->${ROW_END} (image ${COLS}x${ROWS} cells), text scroll ${TEXT_SCROLL}" >&2
fi
echo "Ctrl-C to stop early; the image is deleted on a clean exit." >&2

exec 3>"$TTY_PATH" || {
  echo "failed to open ${TTY_PATH} for writing" >&2
  exit 1
}

cleanup() {
  # d=I (not the default "i"): full teardown, matching build_delete's
  # free_data=true path used by blit's own VimLeavePre/free_data cleanup,
  # since this script exits entirely rather than caching the id for reuse.
  # Every step below is guarded with `|| true`: fd 3 may already be closed
  # or invalid (e.g. the tty went away along with a WezTerm crash), and this
  # is best-effort teardown -- a failed write here must never itself abort
  # cleanup and mask the underlying failure being diagnosed.
  printf '%s' "${APC_START}a=d,d=I,i=${IMAGE_ID}${APC_END}" >&3 2>/dev/null || true
  if [ "$SCROLL_REGION" = "1" ]; then
    # Reset the scroll region to the full screen (DECSTBM with no args).
    printf '%s' "${ESC}[r" >&3 2>/dev/null || true
  fi
  exec 3>&- 2>/dev/null || true
}
trap cleanup EXIT
trap exit INT TERM   # without this, INT/TERM only run cleanup and the loop keeps going

if [ "$SCROLL_REGION" = "1" ]; then
  printf '%s' "${ESC}[${SCROLL_TOP};${SCROLL_BOTTOM}r" >&3
fi

# Transmit once, matching build_transmit(png_bytes, { id, action="T",
# placement={columns,rows,no_move_cursor=true} }): a=T,f=100,t=d,i=<id>,
# q=2,p=<placement_id>,c=<cols>,r=<rows>,C=1,m=0
printf '%s' "${APC_START}a=T,f=100,t=d,i=${IMAGE_ID},q=2,p=${PLACEMENT_ID},c=${COLS},r=${ROWS},C=1,m=0;${PNG_B64}${APC_END}" >&3

SLEEP_INTERVAL=$(awk -v hz="$RATE_HZ" 'BEGIN { printf "%.4f", 1 / hz }')
START_EPOCH=$(date +%s)
NEXT_HEARTBEAT=$((START_EPOCH + 1))
ITER=0
ROW=$ROW_START

while :; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_EPOCH))
  if [ "$ELAPSED" -ge "$DURATION_SEC" ]; then
    break
  fi

  # Sweep the row continuously toward ROW_END, wrapping back to ROW_START
  # once reached, so the placement visits every distinct row in the range
  # repeatedly rather than toggling between just two fixed rows.
  if [ "$ROW" -eq "$ROW_END" ]; then
    ROW=$ROW_START
  else
    ROW=$((ROW + ROW_STEP))
  fi

  if [ "$SCROLL_REGION" = "1" ]; then
    # Move to the scroll region's own bottom row, then write text + newline
    # there -- scrolling happens only within [SCROLL_TOP, SCROLL_BOTTOM],
    # leaving row 1 and the last row untouched, like Neovim's tabline/
    # statusline chrome outside its own DECSTBM region.
    printf '%s' "${ESC}[${SCROLL_BOTTOM};1H"
    printf 'line %06d: the quick brown fox jumps over the lazy dog\n' "$ITER"
  elif [ "$TEXT_SCROLL" = "1" ]; then
    # Emit one line of ordinary text at the cursor's own position (bottom of
    # the screen, wherever the terminal has it) BEFORE repositioning the
    # placement. This is real line-feed scrolling of on-screen content --
    # the piece v1/v2 never did -- kept in lockstep with the row sweep (one
    # text line per one row of sweep) to mirror the manual repro, where the
    # image's screen row shifts by exactly one line per line scrolled.
    printf 'line %06d: the quick brown fox jumps over the lazy dog\n' "$ITER"
  fi >&3

  # save-cursor, move-cursor, a=p reposition, restore-cursor -- matching
  # place_existing() in lua/blit/renderer.lua, built from
  # build_save_cursor/build_move_cursor/build_placement/build_restore_cursor.
  printf '%s' "${ESC}7${ESC}[${ROW};1H${APC_START}a=p,i=${IMAGE_ID},p=${PLACEMENT_ID},c=${COLS},r=${ROWS},C=1,q=2${APC_END}${ESC}8" >&3

  ITER=$((ITER + 1))
  if [ "$NOW" -ge "$NEXT_HEARTBEAT" ]; then
    echo "t=${ELAPSED}s iter=${ITER} ($(date '+%H:%M:%S'))" >&2
    NEXT_HEARTBEAT=$((NOW + 1))
  fi

  sleep "$SLEEP_INTERVAL"
done

echo "completed ${DURATION_SEC}s without the script's own tty write failing (${ITER} bursts sent)." >&2
