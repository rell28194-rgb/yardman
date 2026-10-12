import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
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

    def build_apk(self, path: Path, manifest, tile, *, include_tile=True, mutate_manifest=False):
        packaged_manifest = dict(manifest)
        if mutate_manifest:
            packaged_manifest["source_sha256"] = "wrong"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("assets/data/roads/streetlights/manifest.json", json.dumps(packaged_manifest))
            if include_tile:
                archive.writestr("assets/data/roads/streetlights/tile_0_0.json", json.dumps(tile))

    def test_valid_dataset_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, manifest, tile = self.dataset(root)
            apk = root / "ok.apk"
            self.build_apk(apk, manifest, tile)
            result = validate(apk, manifest_path)
            self.assertEqual(result["features"], 1)
            self.assertEqual(result["tiles"], 1)

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


if __name__ == "__main__":
    unittest.main()
