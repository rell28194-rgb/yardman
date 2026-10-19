import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from road_route_pack import EDGE, HEADER, NODE, ROUTE_PACK_MAGIC, ROUTE_PACK_VERSION
from validate_packaged_authority import validate


class PackagedAuthorityValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source_sha = "a" * 64
        self.origin = {"easting": 1.0, "northing": 2.0}
        self.parish_names = [
            "Clarendon", "Hanover", "Kingston", "Manchester", "Portland", "St. Andrew", "St. Ann",
            "St. Catherine", "St. Elizabeth", "St. James", "St. Mary", "St. Thomas", "Trelawny", "Westmoreland",
        ]
        self.route_bytes = HEADER.pack(
            ROUTE_PACK_MAGIC,
            ROUTE_PACK_VERSION,
            HEADER.size,
            NODE.size,
            EDGE.size,
            0,
            0,
            0,
            0,
        )
        self.roads = {
            "source_sha256": self.source_sha,
            "crs": "EPSG:3448",
            "origin": self.origin,
            "graph": {
                "nodes": 0,
                "edges": 0,
                "route_pack": {
                    "format": ROUTE_PACK_VERSION,
                    "file": "routes.ymr",
                    "bytes": len(self.route_bytes),
                    "sha256": hashlib.sha256(self.route_bytes).hexdigest(),
                    "nodes": 0,
                    "edges": 0,
                    "header_bytes": HEADER.size,
                    "node_record_bytes": NODE.size,
                    "edge_record_bytes": EDGE.size,
                },
            },
        }
        self.places = {
            "source_sha256": self.source_sha,
            "crs": "EPSG:3448",
            "origin": self.origin,
            "tiles": {
                "0:0": [
                    {
                        "source": "osm/test",
                        "parish": "Kingston",
                        "parish_assignment": "admin_level_6_polygon",
                    }
                ]
            },
            "stats": {
                "places": 1,
                "unresolved_source_records": 0,
                "dropped_synthetic_records": 0,
            },
        }
        self.parishes = {
            "source_sha256": self.source_sha,
            "crs": "EPSG:3448",
            "origin": self.origin,
            "parishes": {name: [] for name in self.parish_names},
            "stats": {"canonical_parishes": 14, "missing_parishes": []},
        }

    def tearDown(self):
        self.temp.cleanup()

    def _write_sources(self):
        roads_path = self.root / "roads.json"
        places_path = self.root / "places.json"
        parishes_path = self.root / "parishes.json"
        roads_path.write_text(json.dumps(self.roads))
        places_path.write_text(json.dumps(self.places))
        parishes_path.write_text(json.dumps(self.parishes))
        return roads_path, places_path, parishes_path

    def _write_apk(self):
        apk = self.root / "Yardman.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("assets/data/roads/manifest.json", json.dumps(self.roads))
            archive.writestr("assets/data/places/manifest.json", json.dumps(self.places))
            archive.writestr("assets/data/parishes/manifest.json", json.dumps(self.parishes))
            archive.writestr("assets/data/roads/graph/routes.ymr", self.route_bytes)
        return apk

    def _set_route(self, payload):
        self.route_bytes = payload
        route = self.roads["graph"]["route_pack"]
        route["bytes"] = len(payload)
        route["sha256"] = hashlib.sha256(payload).hexdigest()

    def test_accepts_current_ymrg_v1_header_contract(self):
        sources = self._write_sources()
        proof = validate(self._write_apk(), *sources)
        self.assertEqual(proof["route_pack_format"], ROUTE_PACK_VERSION)
        self.assertEqual(proof["runtime_places"], 1)
        self.assertEqual(proof["parishes"], 14)

    def test_rejects_legacy_or_unknown_magic_even_with_matching_sha(self):
        payload = bytearray(self.route_bytes)
        payload[:4] = b"YMR1"
        self._set_route(bytes(payload))
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "magic is invalid"):
            validate(self._write_apk(), *sources)

    def test_rejects_route_pack_version_drift(self):
        payload = HEADER.pack(
            ROUTE_PACK_MAGIC,
            ROUTE_PACK_VERSION + 1,
            HEADER.size,
            NODE.size,
            EDGE.size,
            0,
            0,
            0,
            0,
        )
        self._set_route(payload)
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "version differs from manifest"):
            validate(self._write_apk(), *sources)

    def test_rejects_layout_size_drift(self):
        payload = HEADER.pack(
            ROUTE_PACK_MAGIC,
            ROUTE_PACK_VERSION,
            HEADER.size,
            NODE.size + 4,
            EDGE.size,
            0,
            0,
            0,
            0,
        )
        self._set_route(payload)
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "node layout differs from manifest"):
            validate(self._write_apk(), *sources)

    def test_rejects_truncated_binary_body(self):
        payload = HEADER.pack(
            ROUTE_PACK_MAGIC,
            ROUTE_PACK_VERSION,
            HEADER.size,
            NODE.size,
            EDGE.size,
            1,
            0,
            0,
            0,
        )
        self.roads["graph"]["nodes"] = 1
        self.roads["graph"]["route_pack"]["nodes"] = 1
        self._set_route(payload)
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "byte layout is inconsistent"):
            validate(self._write_apk(), *sources)


if __name__ == "__main__":
    unittest.main()
