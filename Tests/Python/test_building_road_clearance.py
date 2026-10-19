from pathlib import Path
import gzip
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_buildings import write_pack, read_cell
from filter_building_road_overlaps import filter_dataset


def building_record(identifier, x0, z0, x1, z1):
    ring = [[x0, 0.0, z0], [x1, 0.0, z0], [x1, 0.0, z1], [x0, 0.0, z1], [x0, 0.0, z0]]
    return [identifier, 4.4, 3, 0, 4.4, [ring], [[x0, z0], [x1, z0], [x1, z1], [x0, z1]], [0, 2, 1, 0, 3, 2]]


class BuildingRoadClearanceTests(unittest.TestCase):
    def test_same_grade_overlap_is_removed_but_bridge_crossing_is_kept(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            roads = root / "roads"
            buildings = root / "buildings"
            roads.mkdir()
            buildings.mkdir()

            road_segments = [
                [10.0, 10.0, 30.0, 10.0, 4.0, 0, 0, "road", 0, 0.0, 0.0,
                 [[10.0, 0.0, 8.0], [10.0, 0.0, 12.0], [30.0, 0.0, 12.0], [30.0, 0.0, 8.0]]],
                [60.0, 10.0, 80.0, 10.0, 4.0, 0, 2, "bridge", 0, 5.0, 5.0,
                 [[60.0, 5.0, 8.0], [60.0, 5.0, 12.0], [80.0, 5.0, 12.0], [80.0, 5.0, 8.0]]],
            ]
            (roads / "tile_0_0.json").write_text(json.dumps({"tile": [0, 0], "segments": road_segments}), encoding="utf-8")
            (roads / "manifest.json").write_text(json.dumps({
                "tile_size": 4096.0,
                "source_sha256": "road-source",
                "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "segments": 2}],
            }), encoding="utf-8")

            records = [
                building_record("w-overlap:0", 15.0, 9.0, 20.0, 13.0),
                building_record("w-clear:0", 40.0, 20.0, 45.0, 25.0),
                building_record("w-under-bridge:0", 65.0, 9.0, 70.0, 13.0),
            ]
            raw = json.dumps(records, separators=(",", ":")).encode()
            write_pack(buildings / "buildings_0_0.ymb", [(0, 0, gzip.compress(raw, compresslevel=6, mtime=0))])
            (buildings / "manifest.json").write_text(json.dumps({
                "format": 1,
                "tile_size": 4096,
                "cell_size": 256,
                "stats": {"buildings": 3},
                "tiles": [{"x": 0, "z": 0, "file": "buildings_0_0.ymb", "cells": [[0, 0]]}],
            }), encoding="utf-8")

            audit_path = root / "overlap-audit.json"
            audit = filter_dataset(buildings, roads, audit_path=audit_path, min_overlap_m2=0.75)

            self.assertEqual(audit["buildings_checked"], 3)
            self.assertEqual(audit["rejected_road_overlap"], 1)
            self.assertEqual(audit["buildings_kept"], 2)
            self.assertEqual(audit["conflicts"][0]["building_part_id"], "w-overlap:0")
            kept = read_cell(buildings / "buildings_0_0.ymb", 0, 0)
            self.assertEqual([record[0] for record in kept], ["w-clear:0", "w-under-bridge:0"])
            manifest = json.loads((buildings / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["stats"]["buildings"], 2)
            self.assertEqual(manifest["stats"]["rejected_road_overlap"], 1)
            self.assertTrue(audit_path.exists())

    def test_rejects_invalid_overlap_threshold(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                filter_dataset(root / "missing-buildings", root / "missing-roads", min_overlap_m2=0.0)


if __name__ == "__main__":
    unittest.main()
