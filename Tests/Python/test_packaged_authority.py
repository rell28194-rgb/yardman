import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from validate_packaged_authority import validate


class PackagedAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.apk = self.root / "test.apk"
        self.roads_path = self.root / "roads.json"
        self.places_path = self.root / "places.json"
        self.parishes_path = self.root / "parishes.json"

        self.route = b"YMR1" + b"\0" * 60
        route_sha = hashlib.sha256(self.route).hexdigest()
        self.roads = {
            "crs": "EPSG:3448",
            "source_sha256": "a" * 64,
            "origin": {"easting": 1.0, "northing": 2.0},
            "graph": {
                "nodes": 3,
                "edges": 2,
                "route_pack": {"file": "routes.ymr", "sha256": route_sha, "nodes": 3, "edges": 2},
            },
        }
        self.places = {
            "crs": "EPSG:3448",
            "source_sha256": "a" * 64,
            "origin": {"easting": 1.0, "northing": 2.0},
            "tiles": {"0:0": [{"name": "Kingston", "source": "node/1", "parish": "Kingston", "parish_assignment": "admin_level_6_polygon"}]},
            "stats": {"places": 1, "unresolved_source_records": 2, "dropped_synthetic_records": 1},
        }
        self.parishes = {
            "crs": "EPSG:3448",
            "source_sha256": "a" * 64,
            "origin": {"easting": 1.0, "northing": 2.0},
            "parishes": {f"P{i}": [] for i in range(14)},
            "stats": {"canonical_parishes": 14, "missing_parishes": []},
        }
        self._write_sources()
        self._write_apk()

    def tearDown(self):
        self.tmp.cleanup()

    def _write_sources(self):
        self.roads_path.write_text(json.dumps(self.roads))
        self.places_path.write_text(json.dumps(self.places))
        self.parishes_path.write_text(json.dumps(self.parishes))

    def _write_apk(self, *, route=None, places=None, parishes=None):
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("assets/data/roads/manifest.json", json.dumps(self.roads))
            archive.writestr("assets/data/roads/graph/routes.ymr", self.route if route is None else route)
            archive.writestr("assets/data/places/manifest.json", json.dumps(self.places if places is None else places))
            archive.writestr("assets/data/parishes/manifest.json", json.dumps(self.parishes if parishes is None else parishes))

    def test_valid_authority_passes(self):
        proof = validate(self.apk, self.roads_path, self.places_path, self.parishes_path)
        self.assertEqual(proof["parishes"], 14)
        self.assertEqual(proof["runtime_places"], 1)
        self.assertEqual(proof["route_pack_sha256"], self.roads["graph"]["route_pack"]["sha256"])

    def test_guessed_runtime_place_fails(self):
        bad = json.loads(json.dumps(self.places))
        bad["tiles"]["0:0"][0]["parish_assignment"] = "nearest_capital_fallback"
        bad["tiles"]["0:0"][0]["parish"] = "St. Andrew"
        self.places_path.write_text(json.dumps(bad))
        self._write_apk(places=bad)
        with self.assertRaisesRegex(ValueError, "guessed parish assignment"):
            validate(self.apk, self.roads_path, self.places_path, self.parishes_path)

    def test_route_pack_hash_mismatch_fails(self):
        self._write_apk(route=b"YMR1" + b"x" * 60)
        with self.assertRaisesRegex(ValueError, "route pack SHA"):
            validate(self.apk, self.roads_path, self.places_path, self.parishes_path)


if __name__ == "__main__":
    unittest.main()
