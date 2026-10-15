import json
import sys
import tempfile
import unittest
import warnings
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

    def test_rejects_packaged_manifest_drift(self):
        sources = self._write_sources()
        packaged = deepcopy(self.places)
        packaged["stats"]["places"] = 13
        with self.assertRaisesRegex(ValueError, "differs from compiled Jamaica source"):
            validate(self._write_apk(places=packaged), *sources)

    def test_rejects_missing_canonical_parish_even_when_source_matches(self):
        missing = deepcopy(self.parishes)
        missing["parishes"].pop("Portland")
        missing["stats"]["canonical_parishes"] = 13
        source_paths = self._write_sources(parishes=missing)
        with self.assertRaisesRegex(ValueError, "parish set is not canonical"):
            validate(self._write_apk(parishes=missing), *source_paths)

    def test_rejects_place_coverage_gap(self):
        places = deepcopy(self.places)
        places["stats"]["by_parish"].pop("St. Thomas")
        source_paths = self._write_sources(places=places)
        with self.assertRaisesRegex(ValueError, "cover exactly all fourteen parishes"):
            validate(self._write_apk(places=places), *source_paths)

    def test_rejects_duplicate_geography_authority_payload(self):
        sources = self._write_sources()
        apk = self._write_apk(extras={"assets/data/places/tile_0_0.json": "{}"})
        with self.assertRaisesRegex(ValueError, "duplicate geography payloads"):
            validate(apk, *sources)

    def test_rejects_consistently_wrong_crs(self):
        self.roads["crs"] = self.places["crs"] = self.parishes["crs"] = "EPSG:4326"
        sources = self._write_sources()
        with self.assertRaisesRegex(ValueError, "must be EPSG:3448"):
            validate(self._write_apk(), *sources)

    def test_rejects_invalid_coordinates_even_when_source_matches(self):
        for family in ("place", "capital"):
            for axis in ("x", "z"):
                for invalid in (float("inf"), float("-inf"), float("nan"), None, "100", True):
                    with self.subTest(family=family, axis=axis, invalid=invalid):
                        places = deepcopy(self.places)
                        record = (places["tiles"]["0:0"][0] if family == "place"
                                  else places["parish_capitals"]["Kingston"])
                        record[axis] = invalid
                        sources = self._write_sources(places=places)
                        with self.assertRaisesRegex(ValueError, "invalid finite coordinate"):
                            validate(self._write_apk(places=places), *sources)

    def test_rejects_actual_parish_coverage_gap_despite_claimed_counts(self):
        places = deepcopy(self.places)
        places["tiles"]["0:0"][0]["parish"] = places["tiles"]["0:0"][1]["parish"]
        sources = self._write_sources(places=places)
        with self.assertRaisesRegex(ValueError, "Actual per-parish place counts"):
            validate(self._write_apk(places=places), *sources)

    def test_rejects_duplicate_zip_authority_entry(self):
        sources = self._write_sources()
        for family in ("places", "parishes", "roads"):
            with self.subTest(family=family):
                apk = self._write_apk()
                name = "assets/data/" + family + "/manifest.json"
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    with zipfile.ZipFile(apk, "a") as archive:
                        archive.writestr(name, "{}")
                        if family == "roads":
                            archive.writestr(name, "{}")
                with self.assertRaisesRegex(ValueError, "Duplicate ZIP geography authority entry"):
                    validate(apk, *sources)


if __name__ == "__main__":
    unittest.main()
