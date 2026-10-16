import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from validate_fence_apk import APK_ROOT, PURPOSE, WIRE_RULE, validate


class FenceApkValidationTest(unittest.TestCase):
    def fixture(self, root: Path):
        source = root / "fences"
        source.mkdir()
        tile = {
            "tile": [-1, -1],
            "fences": [
                {"source_way": "w1", "line": 0, "segment": 0, "start": [-20.0, -30.0], "end": [-10.0, -30.0], "barrier": "fence", "fence_type": "chain_link", "material": "unspecified", "wire_compatible": True},
                {"source_way": "w2", "line": 0, "segment": 0, "start": [-20.0, -40.0], "end": [-10.0, -40.0], "barrier": "fence", "fence_type": "unspecified", "material": "unspecified", "wire_compatible": False},
            ],
        }
        (source / "tile_-1_-1.json").write_text(json.dumps(tile), encoding="utf-8")
        manifest = {
            "format": 1,
            "purpose": PURPOSE,
            "wire_compatibility_rule": WIRE_RULE,
            "crs": "EPSG:3448",
            "source_sha256": "fixture",
            "stats": {"features": 2, "wire_compatible_features": 1, "source_segments": 2, "tile_pieces": 2, "tiles": 1},
            "tiles": [{"x": -1, "z": -1, "file": "tile_-1_-1.json", "records": 2}],
        }
        manifest_path = source / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        return manifest_path, manifest, tile

    def test_exact_packaged_dataset_passes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest_path, manifest, tile = self.fixture(root)
            apk = root / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(APK_ROOT + "manifest.json", json.dumps(manifest))
                archive.writestr(APK_ROOT + "tile_-1_-1.json", json.dumps(tile))
            result = validate(apk, manifest_path)
            self.assertEqual(result["features"], 2)
            self.assertEqual(result["wire_compatible_features"], 1)
            self.assertEqual(result["tile_pieces"], 2)

    def test_missing_tile_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest_path, manifest, _ = self.fixture(root)
            apk = root / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(APK_ROOT + "manifest.json", json.dumps(manifest))
            with self.assertRaises(ValueError):
                validate(apk, manifest_path)

    def test_non_boolean_wire_compatibility_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest_path, manifest, tile = self.fixture(root)
            tile["fences"][0]["wire_compatible"] = "yes"
            (manifest_path.parent / "tile_-1_-1.json").write_text(json.dumps(tile), encoding="utf-8")
            apk = root / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(APK_ROOT + "manifest.json", json.dumps(manifest))
                archive.writestr(APK_ROOT + "tile_-1_-1.json", json.dumps(tile))
            with self.assertRaises(ValueError):
                validate(apk, manifest_path)


if __name__ == "__main__":
    unittest.main()
