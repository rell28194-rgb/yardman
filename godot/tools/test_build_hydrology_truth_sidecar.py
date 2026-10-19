#!/usr/bin/env python3
import json
import tempfile
from pathlib import Path

from build_hydrology_truth_sidecar import build_sidecar, load_registered_segments


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "hydrology"
        (root / "tiles").mkdir(parents=True)
        key_a = "1:2:w10:1.000000:2.000000:3.000000:4.000000"
        key_b = "1:2:w11:5.000000:6.000000:7.000000:8.000000"
        record_format = ["ax", "ay", "az", "bx", "by", "bz", "source_way", "segment_key"]
        (root / "tiles/tile_1_2.json").write_text(json.dumps({
            "tile": [1, 2],
            "segments": [[1, 10, 2, 3, 9, 4, "w10", key_a], [5, 8, 6, 7, 7, 8, "w11", key_b]],
        }))
        (root / "manifest.json").write_text(json.dumps({
            "record_format": record_format,
            "tiles": [{"x": 1, "z": 2, "file": "tiles/tile_1_2.json", "segments": 2}],
        }))
        segments = load_registered_segments(root)
        assert [s["segment_key"] for s in segments] == [key_a, key_b]

        evidence = Path(tmp) / "evidence.json"
        evidence.write_text(json.dumps({"evidence": [{
            "segment_key": key_a,
            "source": "wra",
            "source_feature_id": "lower-morass-01",
            "layer": "hydrology_region",
            "mapped_unit": "Lower Morass",
            "intersection_fraction": 0.75,
            "evidence_token": "wra:black_river_lower_morass_wmu",
            "authorized": True,
        }]}))
        output = Path(tmp) / "truth-sidecar.json"
        pack = build_sidecar(root, output, evidence)
        assert output.is_file()
        assert len(pack["segments"]) == 2
        assert pack["segments"][0]["segment_key"] == key_a
        assert pack["segments"][0]["decision"]["status"] == "approved"
        assert pack["segments"][0]["decision"]["morphology_family"] == "lowland_wetland"
        assert pack["segments"][1]["decision"]["status"] == "blocked"
        assert pack["metrics"]["segments_approved"] == 1
        assert pack["metrics"]["segments_blocked_no_evidence"] == 1

        bad = Path(tmp) / "bad"
        bad.mkdir()
        (bad / "manifest.json").write_text(json.dumps({"record_format": ["source_way"], "tiles": []}))
        try:
            load_registered_segments(bad)
        except ValueError:
            pass
        else:
            raise AssertionError("compiler output without segment_key must fail closed")
    print("HYDROLOGY_TRUTH_SIDECAR_PASS")


if __name__ == "__main__":
    main()
