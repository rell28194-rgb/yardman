import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from validate_guardrail_apk import APK_ROOT, PLACEMENT_RULE, PURPOSE, validate


class GuardRailApkValidationTest(unittest.TestCase):
    def fixture(self, root: Path):
        source = root / "guardrails"
        source.mkdir()
        tile = {
            "tile": [-1, -1],
            "guard_rails": [
                {"source_way": "w1", "line": 0, "segment": 0, "start": [-20.0, -30.0], "end": [-10.0, -30.0], "barrier": "guard_rail", "material": "unspecified"}
            ],
        }
        (source / "tile_-1_-1.json").write_text(json.dumps(tile), encoding="utf-8")
        manifest = {
            "format": 1,
            "purpose": PURPOSE,
            "placement_rule": PLACEMENT_RULE,
            "crs": "EPSG:3448",
            "source_sha256": "fixture",
            "stats": {"features": 1, "source_segments": 1, "tile_pieces": 1, "tiles": 1, "by_material": {"unspecified": 1}},
            "tiles": [{"x": -1, "z": -1, "file": "tile_-1_-1.json", "records": 1}],
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
            self.assertEqual(result["features"], 1)
            self.assertEqual(result["tile_pieces"], 1)

    def test_missing_tile_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest_path, manifest, _ = self.fixture(root)
            apk = root / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(APK_ROOT + "manifest.json", json.dumps(manifest))
            with self.assertRaises(ValueError):
                validate(apk, manifest_path)

    def test_non_guard_rail_record_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest_path, manifest, tile = self.fixture(root)
            tile["guard_rails"][0]["barrier"] = "fence"
            (manifest_path.parent / "tile_-1_-1.json").write_text(json.dumps(tile), encoding="utf-8")
            apk = root / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(APK_ROOT + "manifest.json", json.dumps(manifest))
                archive.writestr(APK_ROOT + "tile_-1_-1.json", json.dumps(tile))
            with self.assertRaises(ValueError):
                validate(apk, manifest_path)


if __name__ == "__main__":
    unittest.main()
