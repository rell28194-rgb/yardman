import json
import sys
import tempfile
import unittest
import zipfile
from copy import deepcopy
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from validate_geography_apk import CANONICAL_PARISHES, validate


class GeographyApkValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source_sha = "a" * 64
        self.roads = {
            "source_sha256": self.source_sha,
            "crs": "EPSG:3448",
        }
        names = sorted(CANONICAL_PARISHES)
        records = [
            {"name": "Place " + parish, "kind": "town", "parish": parish, "x": index * 1000.0, "z": 0.0}
            for index, parish in enumerate(names)
        ]
        self.places = {
            "source_sha256": self.source_sha,
            "crs": "EPSG:3448",
            "parish_capitals": {
                parish: {"name": "Capital " + parish, "x": index * 1000.0, "z": 0.0}
                for index, parish in enumerate(names)
            },
            "tiles": {"0:0": records},
            "stats": {
                "places": len(records),
                "tiles": 1,
                "by_parish": {parish: 1 for parish in names},
            },
        }
        self.parishes = {
            "source_sha256": self.source_sha,
            "crs": "EPSG:3448",
            "parishes": {parish: [] for parish in names},
            "stats": {"canonical_parishes": 14, "missing_parishes": []},
        }

    def tearDown(self):
        self.temp.cleanup()

    def _write_sources(self, places=None, parishes=None):
        road_path = self.root / "roads.json"
        places_path = self.root / "places.json"
        parishes_path = self.root / "parishes.json"
        road_path.write_text(json.dumps(self.roads))
        places_path.write_text(json.dumps(self.places if places is None else places))
        parishes_path.write_text(json.dumps(self.parishes if parishes is None else parishes))
        return road_path, places_path, parishes_path

    def _write_apk(self, places=None, parishes=None, extras=None):
        apk = self.root / "Yardman.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("assets/data/places/manifest.json", json.dumps(self.places if places is None else places))
            archive.writestr("assets/data/parishes/manifest.json", json.dumps(self.parishes if parishes is None else parishes))
            for name, payload in (extras or {}).items():
                archive.writestr(name, payload)
        return apk

    def test_accepts_exact_all_parish_package(self):
        sources = self._write_sources()
        proof = validate(self._write_apk(), *sources)
        self.assertEqual(proof["parishes"], 14)
        self.assertEqual(proof["places"], 14)
        self.assertEqual(proof["place_tiles"], 1)
        self.assertEqual(proof["crs"], "EPSG:3448")
        self.assertEqual(proof["source_sha256"], self.source_sha)

    def test_rejects_packaged_manifest_drift(self):
        sources = self._write_sources()
        packaged = deepcopy(self.places)
        packaged["stats"]["places"] = 13
        with self.assertRaisesRegex(ValueError, "differs from compiled Jamaica source"):
            validate(self._write_apk(places=packaged), *sources)

    def test_rejects_invalid_road_source_digest(self):
        self.roads["source_sha256"] = "not-a-sha"
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "valid source SHA-256"):
            validate(self._write_apk(), *sources)

    def test_rejects_source_registration_mismatch(self):
        self.roads["source_sha256"] = "b" * 64
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "source registration differs"):
            validate(self._write_apk(), *sources)

    def test_rejects_noncanonical_crs_even_when_all_manifests_agree(self):
        self.roads["crs"] = "EPSG:4326"
        places = deepcopy(self.places)
        parishes = deepcopy(self.parishes)
        places["crs"] = "EPSG:4326"
        parishes["crs"] = "EPSG:4326"
        source_paths = self._write_sources(places=places, parishes=parishes)
        with self.assertRaisesRegex(ValueError, "canonical Jamaica Metric Grid"):
            validate(self._write_apk(places=places, parishes=parishes), *source_paths)

    def test_rejects_missing_canonical_parish_even_when_source_matches(self):
        missing = deepcopy(self.parishes)
        missing["parishes"].pop("Portland")
        missing["stats"]["canonical_parishes"] = 13
        source_paths = self._write_sources(parishes=missing)
        with self.assertRaisesRegex(ValueError, "parish set is not canonical"):
            validate(self._write_apk(parishes=missing), *source_paths)

    def test_rejects_missing_capital_anchor(self):
        places = deepcopy(self.places)
        places["parish_capitals"].pop("Kingston")
        source_paths = self._write_sources(places=places)
        with self.assertRaisesRegex(ValueError, "omitted canonical parish-capital anchors"):
            validate(self._write_apk(places=places), *source_paths)

    def test_rejects_place_coverage_gap(self):
        places = deepcopy(self.places)
        places["stats"]["by_parish"].pop("St. Thomas")
        source_paths = self._write_sources(places=places)
        with self.assertRaisesRegex(ValueError, "cover exactly all fourteen parishes"):
            validate(self._write_apk(places=places), *source_paths)

    def test_rejects_unknown_place_parish(self):
        places = deepcopy(self.places)
        places["tiles"]["0:0"][0]["parish"] = "Unknown"
        source_paths = self._write_sources(places=places)
        with self.assertRaisesRegex(ValueError, "non-canonical parish"):
            validate(self._write_apk(places=places), *source_paths)

    def test_rejects_duplicate_geography_authority_payload(self):
        sources = self._write_sources()
        apk = self._write_apk(extras={"assets/data/places/tile_0_0.json": "{}"})
        with self.assertRaisesRegex(ValueError, "duplicate geography payloads"):
            validate(apk, *sources)


if __name__ == "__main__":
    unittest.main()
