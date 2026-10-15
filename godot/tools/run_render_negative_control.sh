#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <renderer> <control> <panel> <capture-dir> <log>" >&2
  exit 64
fi

renderer=$1
control=$2
panel=$3
capture_dir=$4
log=$5

case "$control" in
  missing_panel|flat_panel|black_panel) ;;
  *) echo "unknown render control: $control" >&2; exit 64 ;;
esac
case "$panel" in
  0|1|2|3|4|5) ;;
  *) echo "invalid render control panel: $panel" >&2; exit 64 ;;
esac

mkdir -p "$(dirname "$log")" "$capture_dir"
set +e
YARDMAN_RENDER_FIXTURE_CONTROL="$control" \
YARDMAN_RENDER_FIXTURE_CONTROL_PANEL="$panel" \
YARDMAN_RENDER_CAPTURE_DIR="$capture_dir" \
timeout 120 xvfb-run -a -s '-screen 0 960x540x24' \
  godot --path godot --rendering-method "$renderer" --audio-driver Dummy \
  --script res://tests/render_runtime_capture_test.gd > "$log" 2>&1
status=$?
set -e

if grep -E 'SCRIPT ERROR|Parse Error' "$log"; then
  cat "$log"
  exit 1
fi
if ! grep -q "Production shader panel ${panel} .*lost its material signature" "$log"; then
  cat "$log"
  echo "negative control did not trip its selected material panel" >&2
  exit 1
fi
if ! grep -q 'YARDMAN_RENDER_RUNTIME_CAPTURE_TEST FAIL' "$log"; then
  cat "$log"
  echo "negative control did not emit the render failure marker" >&2
  exit 1
fi

# Some software Vulkan runners keep llvmpipe/Xvfb alive after the test has
# already written its deterministic FAIL marker and report. A timeout is only
# acceptable after both expected failure markers above have been proven.
if [ "$status" -eq 0 ]; then
  cat "$log"
  echo "negative render control unexpectedly exited successfully" >&2
  exit 1
fi
if [ "$status" -ne 1 ] && [ "$status" -ne 124 ]; then
  cat "$log"
  echo "negative render control exited unexpectedly: $status" >&2
  exit "$status"
fi
if [ "$status" -eq 124 ]; then
  echo "YARDMAN_RENDER_NEGATIVE_CONTROL_EXIT_TIMEOUT_ACCEPTED renderer=$renderer control=$control panel=$panel fail_marker=1"
fi

echo "YARDMAN_RENDER_NEGATIVE_CONTROL PASS renderer=$renderer control=$control panel=$panel status=$status"
