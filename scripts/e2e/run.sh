#!/usr/bin/env bash
# Run scripts/e2e/scenario.lua in a real terminal and check what it draws.
#
#   scripts/e2e/run.sh <kitty|wezterm|ghostty>
#
# macOS only. The terminal you start this from needs Screen Recording
# (screencapture) and Accessibility (window resize, see resize.py) permissions.
# Prints one PASS/FAIL line per check. Screenshots are deleted unless a
# check fails; failed ones are kept, downscaled, under .e2e/ in the repo.
# Under AeroSpace the test window is switched to floating; stay on the
# current workspace while it runs.
set -euo pipefail

term=${1:-}
case "$term" in
  kitty | wezterm | ghostty) ;;
  *)
    sed -n '2,10p' "$0" >&2
    exit 2
    ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
run_dir="$root/.e2e/$(date +%Y%m%d-%H%M%S)-$term"
results="$run_dir/results.txt"
title="blit-e2e"
mkdir -p "$run_dir"
: >"$results"
python3 "$here/check.py" fixture "$run_dir/fixture.png"
# Same layout, every color shifted: the "overwritten file" check (#11) shows it.
python3 "$here/check.py" fixture "$run_dir/variant.png" 3

# Ghostty is started through `open`, which does not pass this shell's PATH on.
nvim_bin=$(command -v nvim)
inner="cd '$root' && PATH='$PATH' BLIT_E2E_DIR='$run_dir' BLIT_E2E_TERMINAL='$term'"
inner="$inner '$nvim_bin' --clean -u scripts/e2e/scenario.lua"
inner="$inner; touch '$run_dir/exited'; sleep 3"

# Drop variables inherited from the terminal running this script, so blit's
# detection only sees the terminal under test.
clean_env=(env -u KITTY_WINDOW_ID -u TERM_PROGRAM -u TERM_PROGRAM_VERSION -u TMUX)

# Use the binary on PATH, or the one inside the app bundle.
app_bin() {
  command -v "$1" 2>/dev/null || echo "/Applications/$2.app/Contents/MacOS/$1"
}

case "$term" in
  kitty)
    "${clean_env[@]}" "$(app_bin kitty kitty)" -o remember_window_size=no \
      -o initial_window_width=100c -o initial_window_height=40c sh -c "$inner" >/dev/null 2>&1 &
    ;;
  wezterm)
    "${clean_env[@]}" "$(app_bin wezterm WezTerm)" --config initial_cols=100 --config initial_rows=40 \
      start --always-new-process -- sh -c "$inner" >/dev/null 2>&1 &
    ;;
  ghostty)
    open -na Ghostty --args --window-width=100 --window-height=40 -e sh -c "$inner"
    ;;
esac

# Prints "<window id>\t<owner pid>" for the window titled blit-e2e.
find_window() {
  osascript -l JavaScript -e '
    ObjC.import("CoreGraphics");
    function run(argv) {
      const list = ObjC.deepUnwrap(ObjC.castRefToObject(
        $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
      const w = list.find((w) => (w.kCGWindowName || "").includes(argv[0]));
      return w ? w.kCGWindowNumber + "\t" + w.kCGWindowOwnerPID : "";
    }' "$title"
}

resize_window() {
  python3 "$here/resize.py" "$owner_pid" "$1" "$2"
}

# Find the test window, retrying while nvim sets its title.
setup_window() {
  local i
  for i in $(seq 50); do
    IFS=$'\t' read -r window_id owner_pid < <(find_window) || true
    [[ -n "$window_id" ]] && break
    sleep 0.1
  done
  [[ -n "$window_id" ]] || return 1
  # A tiling WM would resize the window under the test and undo resize_window.
  if command -v aerospace >/dev/null 2>&1; then
    aerospace layout --window-id "$window_id" floating
  fi
}

json_get() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"
}

screenshot() {
  screencapture -x -o -t bmp -l "$window_id" "${1%.json}.bmp"
}

# Run `check.py <calibrate|analyze>` on a request's screenshot. The screenshot
# is kept, downscaled, only if the check fails.
check() {
  local command=$1 req=$2 base=${2%.json}
  if python3 "$here/check.py" "$command" "$req" "$base.bmp" "$run_dir/calib.json" >>"$results"; then
    rm -f "$base.bmp"
  else
    sips -s format png -Z 1200 "$base.bmp" --out "$base.png" >/dev/null
    rm -f "$base.bmp"
    echo "  screenshot: $base.png" >>"$results"
  fi
}

# A resize can move the whole cell grid (kitty centers it in the window), so
# screenshots taken after one are checked only once the grid is measured again.
capture() {
  screenshot "$1"
  if [[ -n "$needs_calibration" ]]; then
    awaiting_calibration+=("$1")
  else
    check analyze "$1"
  fi
}

calibrate() {
  screenshot "$1"
  check calibrate "$1"
  needs_calibration=""
  local req
  # The guard keeps an empty array from tripping `set -u` on bash < 4.4.
  for req in ${awaiting_calibration[@]+"${awaiting_calibration[@]}"}; do
    check analyze "$req"
  done
  awaiting_calibration=()
}

window_id=""
owner_pid=""
resize_failed=""
needs_calibration=""
awaiting_calibration=()
n=1
deadline=$((SECONDS + 300))
while ((SECONDS < deadline)); do
  req=$(printf '%s/req-%03d.json' "$run_dir" "$n")
  if [[ ! -f "$req" ]]; then
    sleep 0.1
    continue
  fi
  case "$(json_get "$req" type)" in
    ready)
      if ! setup_window; then
        echo "FAIL setup: window titled $title not found (Screen Recording permission?)" >>"$results"
        break
      fi
      ;;
    capture)
      # A check that relies on a resize proves nothing if the resize did not happen.
      if [[ -n "$resize_failed" && "$(json_get "$req" name)" == *resize* ]]; then
        echo "SKIP $(json_get "$req" name): window was not resized" >>"$results"
      else
        capture "$req"
      fi
      ;;
    calibrate) calibrate "$req" ;;
    result) json_get "$req" line >>"$results" ;;
    resize)
      needs_calibration=1
      if ! resize_window "$(json_get "$req" dw)" "$(json_get "$req" dh)" 2>"$run_dir/resize.err"; then
        if [[ -z "$resize_failed" ]]; then
          echo "FAIL resize: $(tr '\n' ' ' <"$run_dir/resize.err")" >>"$results"
          echo "  give Accessibility permission to the app running make (System Settings > Privacy & Security)" >>"$results"
        fi
        resize_failed=1
      fi
      ;;
    error)
      echo "FAIL scenario: $(json_get "$req" message)" >>"$results"
      break
      ;;
    quit)
      while [[ ! -f "$run_dir/exited" ]] && ((SECONDS < deadline)); do sleep 0.1; done
      sleep 0.5
      capture "$req"
      break
      ;;
  esac
  touch "$(printf '%s/ack-%03d' "$run_dir" "$n")"
  n=$((n + 1))
done
((SECONDS < deadline)) || echo "FAIL timeout: scenario did not finish" >>"$results"
for req in ${awaiting_calibration[@]+"${awaiting_calibration[@]}"}; do
  echo "FAIL $(json_get "$req" name): no calibration after the last resize" >>"$results"
done

echo "== $term"
cat "$results"
if grep -q '^FAIL' "$results"; then
  echo "run dir: $run_dir"
  exit 1
fi
rm -rf "$run_dir"
