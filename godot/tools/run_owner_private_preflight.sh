#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 /path/to/Yardman-Owner-Recovery-Private-Fleet-64-2026-10-19.zip /path/to/Godot_v4.7.2-stable_linux.x86_64" >&2
  exit 2
fi

PACK="$(realpath "$1")"
GODOT="$(realpath "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/private-owner-validation"
mkdir -p "$BUILD"

VERSION="$($GODOT --version | head -n1)"
case "$VERSION" in
  4.7.2.*) ;;
  *) echo "YARDMAN_OWNER_PREFLIGHT_FAIL wrong Godot version: $VERSION" >&2; exit 1 ;;
esac

python3 -m unittest \
  "$ROOT/tests/test_map_cars_integration_scope.py" \
  "$ROOT/tests/test_vehicle_production_scope.py" \
  "$ROOT/tests/test_vehicle_selector_asset_scope.py" \
  2>&1 | tee "$BUILD/static-scope.log"

python3 "$ROOT/tools/stage_owner_fleet_pack.py" "$PACK" \
  --destination "$ROOT/assets/user_reference" \
  --proof "$BUILD/stage-proof.json" \
  2>&1 | tee "$BUILD/stage.log"

timeout 300 "$GODOT" --headless --path "$ROOT" --editor --quit \
  > "$BUILD/import.log" 2>&1
if grep -E 'SCRIPT ERROR|Parse Error|^ERROR:' "$BUILD/import.log"; then
  echo 'YARDMAN_OWNER_PREFLIGHT_FAIL import errors present' >&2
  exit 1
fi

timeout 300 "$GODOT" --headless --path "$ROOT" \
  --script res://tests/owner_vehicle_asset_gate.gd \
  2>&1 | tee "$BUILD/owner-vehicle-asset-gate.log"
grep -q 'YARDMAN_OWNER_VEHICLE_ASSET_GATE PASS vehicles=64 expected=64 missing=0 invalid=0' \
  "$BUILD/owner-vehicle-asset-gate.log"

timeout 300 "$GODOT" --headless --path "$ROOT" \
  --script res://tests/private_owner_fleet_runtime_test.gd \
  2>&1 | tee "$BUILD/private-owner-fleet-runtime.log"
grep -q 'YARDMAN_PRIVATE_OWNER_FLEET_RUNTIME_TEST PASS vehicles=64 dedicated=64 banned_absent=2 held_absent=2' \
  "$BUILD/private-owner-fleet-runtime.log"

python3 - "$BUILD" "$VERSION" <<'PY'
import json, sys
from pathlib import Path
build = Path(sys.argv[1])
proof = json.loads((build / 'stage-proof.json').read_text())
proof.update({
    'godot_version': sys.argv[2],
    'asset_gate': 'PASS',
    'runtime_gate': 'PASS',
    'owner_candidate_preflight': 'PASS',
})
(build / 'owner-private-preflight.json').write_text(json.dumps(proof, indent=2) + '\n')
print('YARDMAN_OWNER_PRIVATE_PREFLIGHT PASS vehicles=64 dedicated=64 renderer_candidate=clean-map-cars')
PY
