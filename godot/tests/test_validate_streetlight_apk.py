import json
import sys
import tempfile
import unittest
import zipfile
import warnings
from copy import deepcopy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from validate_geography_apk import CANONICAL_PARISHES
from validate_streetlight_apk import validate


class StreetlightApkValidationTest(unittest.TestCase):
    def dataset(self, root: Path):
        streetlights = root / "streetlights"
        streetlights.mkdir()
        tile = {
            "tile": [0, 0],
            "street_lights": [
                {
                    "source_node": "n1",
                    "position": [1.0, 2.0],
                    "highway": "street_lamp",
                    "lamp_mount": "unspecified",
                    "support": "unspecified",
                }
            ],
        }
        manifest = {
            "format": 1,
            "purpose": "visual-only explicit OSM highway=street_lamp points; OSM remains geographic authority",
            "placement_rule": "explicit highway=street_lamp nodes only; no inferred spacing or recovered-art placement",
            "crs": "EPSG:3448",
            "source_sha256": "abc",
            "stats": {"features": 1, "tiles": 1},
            "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "records": 1}],
        }
        (streetlights / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        (streetlights / "tile_0_0.json").write_text(json.dumps(tile), encoding="utf-8")
        return streetlights / "manifest.json", manifest, tile

    def build_apk(self, path: Path, manifest, tile, *, include_tile=True, mutate_manifest=False,
                  places=None, parishes=None):
        packaged_manifest = dict(manifest)
        if mutate_manifest:
            packaged_manifest["source_sha256"] = "wrong"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("assets/data/roads/streetlights/manifest.json", json.dumps(packaged_manifest))
            if include_tile:
                archive.writestr("assets/data/roads/streetlights/tile_0_0.json", json.dumps(tile))
            if places is not None:
                archive.writestr("assets/data/places/manifest.json", json.dumps(places))
            if parishes is not None:
                archive.writestr("assets/data/parishes/manifest.json", json.dumps(parishes))

    def national_dataset(self, root: Path):
        data = root / "data"
        roads = data / "roads"
        streetlights = roads / "streetlights"
        places_dir = data / "places"
        parishes_dir = data / "parishes"
        for path in (streetlights, places_dir, parishes_dir):
            path.mkdir(parents=True, exist_ok=True)

        source_sha = "b" * 64
        (roads / "manifest.json").write_text(json.dumps({
            "source_sha256": source_sha,
            "crs": "EPSG:3448",
        }), encoding="utf-8")

        tile = {
            "tile": [0, 0],
            "street_lights": [{
                "source_node": "n1",
                "position": [100.0, 200.0],
                "highway": "street_lamp",
                "lamp_mount": "unspecified",
                "support": "unspecified",
            }],
        }
        streetlight_manifest = {
            "format": 1,
            "purpose": "visual-only explicit OSM highway=street_lamp points; OSM remains geographic authority",
            "placement_rule": "explicit highway=street_lamp nodes only; no inferred spacing or recovered-art placement",
            "crs": "EPSG:3448",
            "source_sha256": source_sha,
            "stats": {"features": 1, "tiles": 1},
            "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "records": 1}],
        }
        streetlight_manifest_path = streetlights / "manifest.json"
        streetlight_manifest_path.write_text(json.dumps(streetlight_manifest), encoding="utf-8")
        (streetlights / "tile_0_0.json").write_text(json.dumps(tile), encoding="utf-8")

        parish_names = sorted(CANONICAL_PARISHES)
        records = [
            {"name": "Place " + parish, "kind": "town", "parish": parish, "x": i * 100.0, "z": 0.0}
            for i, parish in enumerate(parish_names)
        ]
        places = {
            "source_sha256": source_sha,
            "crs": "EPSG:3448",
            "parish_capitals": {
                parish: {"name": "Capital " + parish, "x": i * 100.0, "z": 0.0}
                for i, parish in enumerate(parish_names)
            },
            "tiles": {"0:0": records},
            "stats": {
                "places": len(records),
                "tiles": 1,
                "by_parish": {parish: 1 for parish in parish_names},
            },
        }
        parishes = {
            "source_sha256": source_sha,
            "crs": "EPSG:3448",
            "parishes": {parish: [] for parish in parish_names},
            "stats": {"canonical_parishes": 14, "missing_parishes": []},
        }
        (places_dir / "manifest.json").write_text(json.dumps(places), encoding="utf-8")
        (parishes_dir / "manifest.json").write_text(json.dumps(parishes), encoding="utf-8")
        return streetlight_manifest_path, streetlight_manifest, tile, places, parishes

    def test_valid_dataset_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile = self.dataset(root)
            apk = root / "ok.apk"
            self.build_apk(apk, manifest, tile)
            result = validate(apk, manifest_path)
            self.assertEqual(result["features"], 1)
            self.assertEqual(result["tiles"], 1)
            self.assertNotIn("national_geography", result)

    def test_missing_tile_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile = self.dataset(root)
            apk = root / "missing.apk"
            self.build_apk(apk, manifest, tile, include_tile=False)
            with self.assertRaises(ValueError):
                validate(apk, manifest_path)

    def test_manifest_substitution_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile = self.dataset(root)
            apk = root / "mutated.apk"
            self.build_apk(apk, manifest, tile, mutate_manifest=True)
            with self.assertRaises(ValueError):
                validate(apk, manifest_path)

    def test_full_build_certifies_national_geography(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile, places, parishes = self.national_dataset(root)
            apk = root / "national.apk"
            self.build_apk(apk, manifest, tile, places=places, parishes=parishes)
            result = validate(apk, manifest_path)
            self.assertEqual(result["national_geography"]["parishes"], 14)
            self.assertEqual(result["national_geography"]["places"], 14)

    def test_partial_national_sidecars_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile, places, _parishes = self.national_dataset(root)
            (root / "data" / "parishes" / "manifest.json").unlink()
            apk = root / "partial.apk"
            self.build_apk(apk, manifest, tile)
            with self.assertRaisesRegex(ValueError, "partially present"):
                validate(apk, manifest_path)

    def test_packaged_national_manifest_substitution_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile, places, parishes = self.national_dataset(root)
            drift = deepcopy(places)
            drift["stats"]["places"] -= 1
            apk = root / "drift.apk"
            self.build_apk(apk, manifest, tile, places=drift, parishes=parishes)
            with self.assertRaisesRegex(ValueError, "differs from compiled Jamaica source"):
                validate(apk, manifest_path)

    def test_streetlights_from_different_source_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile, places, parishes = self.national_dataset(root)
            manifest["source_sha256"] = "c" * 64
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            apk = root / "mismatched-source.apk"
            self.build_apk(apk, manifest, tile, places=places, parishes=parishes)
            with self.assertRaisesRegex(ValueError, "source registration differs"):
                validate(apk, manifest_path)

    def test_duplicate_zip_tile_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile = self.dataset(root)
            apk = root / "duplicate.apk"
            self.build_apk(apk, manifest, tile)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(apk, "a") as archive:
                    archive.writestr("assets/data/roads/streetlights/tile_0_0.json", json.dumps(tile))
            with self.assertRaisesRegex(ValueError, "Duplicate street-light ZIP entry"):
                validate(apk, manifest_path)


if __name__ == "__main__":
    unittest.main()
