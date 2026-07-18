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
# Purpose: isolate whether the crash is a WezTerm-side bug in its kitty
# graphics scroll/repaint handling, independent of Neovim and blit's own
# redraw cadence -- issue #31's PR #32 already showed that throttling blit's
# write frequency alone does not stop the crash, so the next diagnostic step
# is to remove Neovim from the loop entirely and see if the same burst,
# sent standalone, still kills the terminal.
#
# Usage:
#   ./scripts/repro-31-wezterm-crash.sh
#
# Run this in a real WezTerm tab (not tmux, not a GUI/embedded terminal).
# It prints a heartbeat line every second to stderr so that if WezTerm's
# process dies mid-run, the last printed timestamp gives an approximate
# time-of-death to correlate against a WezTerm crash log
# (~/Library/Logs/DiagnosticReports/ on macOS, or `wezterm --log-file`).
#
# Manual repro notes from issue #31: the failure is NOT an instant crash --
# held-key scrolling gradually gets more sluggish over the sustained stretch,
# then WezTerm's process dies. That gradual-then-fatal shape is evidence for
# cumulative pty backpressure rather than a one-shot bad escape sequence. This
# script's own heartbeat cadence doubles as a check for the same signature:
# each `printf ... >&3` blocks if the tty's write buffer is backed up, so a
# growing gap between heartbeat timestamps (rather than a steady ~1s cadence)
# would mirror the reported slow-then-crash pattern.
#
# Env vars (all optional):
#   BLIT_REPRO_RATE_HZ       bursts per second (default: 30, matching the
#                            ~30-40Hz key-repeat rate noted in issue #31)
#   BLIT_REPRO_DURATION_SEC  total run time in seconds (default: 180 --
#                            issue #31 only reproduced under a long
#                            *sustained* stretch, not a handful of taps)
#   BLIT_REPRO_COLS          placement width in cells (default: 20)
#   BLIT_REPRO_ROWS          placement height in cells (default: 15)
#   BLIT_REPRO_TTY           tty path to write to (default: auto-probe
#                            /dev/tty then /dev/fd/1, matching blit's own
#                            fallback in lua/blit/terminal.lua)
#
# A minimal 1x1 transparent PNG is embedded below so this script needs no
# external image file and no ImageMagick/base64-generation dependency.

set -u

RATE_HZ="${BLIT_REPRO_RATE_HZ:-30}"
DURATION_SEC="${BLIT_REPRO_DURATION_SEC:-180}"
COLS="${BLIT_REPRO_COLS:-20}"
ROWS="${BLIT_REPRO_ROWS:-15}"

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

echo "blit #31 repro: writing to ${TTY_PATH}, ${RATE_HZ}Hz for ${DURATION_SEC}s (image ${COLS}x${ROWS} cells)" >&2
echo "Ctrl-C to stop early; the image is deleted on a clean exit." >&2

exec 3>"$TTY_PATH" || {
  echo "failed to open ${TTY_PATH} for writing" >&2
  exit 1
}

cleanup() {
  # d=I (not the default "i"): full teardown, matching build_delete's
  # free_data=true path used by blit's own VimLeavePre/free_data cleanup,
  # since this script exits entirely rather than caching the id for reuse.
  printf '%s' "${APC_START}a=d,d=I,i=${IMAGE_ID}${APC_END}" >&3
  exec 3>&-
}
trap cleanup EXIT INT TERM

# Transmit once, matching build_transmit(png_bytes, { id, action="T",
# placement={columns,rows,no_move_cursor=true} }): a=T,f=100,t=d,i=<id>,
# q=2,p=<placement_id>,c=<cols>,r=<rows>,C=1,m=0
printf '%s' "${APC_START}a=T,f=100,t=d,i=${IMAGE_ID},q=2,p=${PLACEMENT_ID},c=${COLS},r=${ROWS},C=1,m=0;${PNG_B64}${APC_END}" >&3

SLEEP_INTERVAL=$(awk -v hz="$RATE_HZ" 'BEGIN { printf "%.4f", 1 / hz }')
START_EPOCH=$(date +%s)
NEXT_HEARTBEAT=$((START_EPOCH + 1))
ITER=0
ROW_TOGGLE=0

while :; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_EPOCH))
  if [ "$ELAPSED" -ge "$DURATION_SEC" ]; then
    break
  fi

  # Alternate the target row each pass so the terminal genuinely has to move
  # the placement (matching a real scroll changing the anchor's screen row),
  # rather than repositioning to an unchanged cell every time.
  if [ "$ROW_TOGGLE" -eq 0 ]; then
    ROW=2
    ROW_TOGGLE=1
  else
    ROW=3
    ROW_TOGGLE=0
  fi

  # save-cursor, move-cursor, a=p reposition, restore-cursor -- matching
  # place_existing() in lua/blit/renderer.lua, built from
  # build_save_cursor/build_move_cursor/build_placement/build_restore_cursor.
  printf '%s' "${ESC}7${ESC}[${ROW};1H${APC_START}a=p,i=${IMAGE_ID},p=${PLACEMENT_ID},c=${COLS},r=${ROWS},C=1${APC_END}${ESC}8" >&3

  ITER=$((ITER + 1))
  if [ "$NOW" -ge "$NEXT_HEARTBEAT" ]; then
    echo "t=${ELAPSED}s iter=${ITER} ($(date '+%H:%M:%S'))" >&2
    NEXT_HEARTBEAT=$((NOW + 1))
  fi

  sleep "$SLEEP_INTERVAL"
done

echo "completed ${DURATION_SEC}s without the script's own tty write failing (${ITER} bursts sent)." >&2
