#!/usr/bin/env bash
set -euo pipefail

# Run the isolated vehicle lifecycle test without loading Yardman's unrelated
# gameplay autoloads. The test only needs project-local scripts/data/assets and
# constructs its own physics floor, so a minimal project removes false startup
# noise from traffic/jobs/garage while preserving the exact vehicle code/data.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GODOT_DIR="$ROOT/godot"
HARNESS="${YARDMAN_VEHICLE_HARNESS_DIR:-/tmp/yardman-vehicle-harness}"
GODOT_BIN="${GODOT_BIN:-godot}"

rm -rf "$HARNESS"
mkdir -p "$HARNESS"
for entry in scripts tests data assets; do
  test -e "$GODOT_DIR/$entry"
  ln -s "$GODOT_DIR/$entry" "$HARNESS/$entry"
done

cat > "$HARNESS/project.godot" <<'EOF'
[application]
config/name="Yardman Vehicle Isolated Harness"

[physics]
common/physics_ticks_per_second=60

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
EOF

LOG="${YARDMAN_VEHICLE_HARNESS_LOG:-/tmp/yardman-vehicle-game-ready.log}"
set +e
"$GODOT_BIN" --headless --path "$HARNESS" --script res://tests/vehicle_game_ready_test.gd 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

# The clean harness must not merely return zero; it must also be free of parser
# and runtime script errors. Vehicle warnings for intentionally absent private
# hero media remain allowed because identity-safe procedural fallback is tested.
if grep -Eq 'SCRIPT ERROR:|ERROR: Failed to load script|ERROR: Failed to instantiate an autoload|Invalid call\.' "$LOG"; then
  echo "YARDMAN_VEHICLE_CLEAN_HARNESS_FAIL unexpected script/runtime error" >&2
  exit 1
fi
if ! grep -q 'YARDMAN_VEHICLE_GAME_READY_TEST PASS' "$LOG"; then
  echo "YARDMAN_VEHICLE_CLEAN_HARNESS_FAIL missing PASS marker" >&2
  exit 1
fi
exit "$STATUS"
