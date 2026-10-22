#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
from pathlib import Path

from build_hydrology_runtime_v2 import compile_runtime_v2


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "truth"
        out = Path(tmp) / "runtime"
        (root / "tiles").mkdir(parents=True)
        fields = ["ax", "ay", "az", "bx", "by", "bz", "source_way", "waterway", "name", "width_m",
                  "width_source", "intermittent", "tidal", "grade_permille", "channel_seed_depth_m",
                  "channel_depth_source", "segment_key"]
        key_a = "0:0:w10:100.000000:200.000000:120.000000:200.000000"
        key_b = "0:0:w10:120.000000:200.000000:140.000000:200.000000"
        tile = {"tile": [0, 0], "segments": [
            [100.0, 12.0, 200.0, 120.0, 11.5, 200.0, "w10", "stream", "Test Stream", 4.0,
             "class_fallback", False, False, -25.0, 0.25, "inferred_seed", key_a],
            [120.0, 11.5, 200.0, 140.0, 11.0, 200.0, "w10", "stream", "Test Stream", 4.0,
             "class_fallback", False, False, -25.0, 0.25, "inferred_seed", key_b],
        ]}
        (root / "tiles" / "tile_0_0.json").write_text(json.dumps(tile), encoding="utf-8")
        manifest = {
            "format": 3, "crs": "EPSG:3448", "axis": "X east, Y elevation, Z south; real metres",
            "origin": {"easting": 0.0, "northing": 0.0}, "tile_size": 4096.0,
            "source": "test", "terrain_source": "test-dem", "record_format": fields,
            "stats": {"segments": 2}, "tiles": [{"x": 0, "z": 0, "file": "tiles/tile_0_0.json", "segments": 2}],
        }
        (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        sidecar = {"segments": [
            {"segment_key": key_a, "decision": {"status": "blocked", "morphology_family": "none"}},
            {"segment_key": key_b, "decision": {"status": "blocked", "morphology_family": "none"}},
        ]}
        (root / "truth-sidecar.json").write_text(json.dumps(sidecar), encoding="utf-8")
        crossings = {"format": 4, "crossings": [{
            "x": 110.0, "z": 200.0, "road_edge": "road-1", "water_source_way": "w10",
            "kind": "bridge", "status": "approved", "terrain_action": "preserve_channel_below",
            "evidence": ["osm:road_bridge"], "source_crossing_evidence": {"bridge": True},
        }]}
        (root / "crossings.json").write_text(json.dumps(crossings), encoding="utf-8")

        result = compile_runtime_v2(root, out)
        assert result["format_version"] == 2
        assert result["pack_id"] == "jamaica_hydrology_reconciled_v2"
        assert result["terrain_mutation_policy"].startswith("runtime pack grants no DEM mutation permission")
        assert int(result["stats"]["segments"]) == 2
        assert int(result["stats"]["crossings"]) == 1
        runtime_tile = json.loads((out / "tile_0_0.json").read_text(encoding="utf-8"))
        assert len(runtime_tile["segments"]) == 2
        first = runtime_tile["segments"][0]
        assert first[1] == 12.0 and first[4] == 11.5, "compiled DEM elevation was not preserved"
        assert first[17] == "blocked" and first[18] == "none"
        assert len(first[19]) == 1 and first[19][0]["kind"] == "bridge"
        assert runtime_tile["segments"][1][19] == []

        # Reconciliation must fail closed if a crossing is not actually on its
        # referenced source waterway geometry.
        crossings["crossings"][0]["x"] = 500.0
        (root / "crossings.json").write_text(json.dumps(crossings), encoding="utf-8")
        try:
            compile_runtime_v2(root, out)
        except ValueError as exc:
            assert "reconciliation exceeded" in str(exc)
        else:
            raise AssertionError("off-geometry crossing was accepted into runtime v2")

    print("YARDMAN_HYDROLOGY_RUNTIME_V2_COMPILER_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
