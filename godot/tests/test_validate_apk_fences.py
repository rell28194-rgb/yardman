import json
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from validate_apk import validate


PURPOSE = "visual-only OSM barrier=fence geometry; OSM remains geographic authority"
RULE = "explicit chain-link/wire/metal/steel/barbed-wire tags only; untyped fences are not assigned recovered chain-link art"


class ApkFenceValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roads = self.root / "data" / "roads"
        self.fences = self.roads / "fences"
        self.fences.mkdir(parents=True)
        self.road_manifest = {
            "crs": "EPSG:3448",
            "source_sha256": "a" * 64,
            "tiles": [{"file": "tile_0_0.bin"}],
            "stats": {"graph_edges": 0},
        }
        self.fence_manifest = {
            "format": 1,
            "purpose": PURPOSE,
            "source_sha256": "a" * 64,
            "crs": "EPSG:3448",
            "wire_compatibility_rule": RULE,
            "stats": {"features": 3, "wire_compatible_features": 2},
            "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "records": 3}],
        }
        (self.roads / "manifest.json").write_text(json.dumps(self.road_manifest))
        (self.fences / "manifest.json").write_text(json.dumps(self.fence_manifest))
        (self.fences / "tile_0_0.json").write_text(json.dumps({"tile": [0, 0], "fences": []}))

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def _arm64_header():
        header = bytearray(20)
        header[:4] = b"\x7fELF"
        struct.pack_into("<H", header, 18, 183)
        return bytes(header)

    def _write_apk(self, *, include_fence_manifest=True, include_fence_tile=True, fence_manifest=None):
        apk = self.root / "fixture.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"fixture")
            archive.writestr("resources.arsc", b"fixture")
            archive.writestr("assets/data/roads/manifest.json", json.dumps(self.road_manifest))
            archive.writestr("assets/data/roads/tile_0_0.bin", b"road")
            archive.writestr("lib/arm64-v8a/libgodot_android.so", self._arm64_header())
            if include_fence_manifest:
                archive.writestr("assets/data/roads/fences/manifest.json", json.dumps(fence_manifest or self.fence_manifest))
            if include_fence_tile:
                archive.writestr("assets/data/roads/fences/tile_0_0.json", json.dumps({"tile": [0, 0], "fences": []}))
        return apk

    def test_valid_fence_sidecar_is_counted(self):
        proof = validate(self._write_apk(), self.roads / "manifest.json")
        self.assertEqual(proof["fence_features"], 3)
        self.assertEqual(proof["wire_fence_features"], 2)
        self.assertEqual(proof["fence_tiles"], 1)
        self.assertEqual(proof["abis"], ["arm64-v8a"])

    def test_missing_fence_manifest_fails(self):
        with self.assertRaisesRegex(ValueError, "fence metadata is missing"):
            validate(self._write_apk(include_fence_manifest=False), self.roads / "manifest.json")

    def test_missing_fence_tile_fails(self):
        with self.assertRaisesRegex(ValueError, "fence tile was omitted"):
            validate(self._write_apk(include_fence_tile=False), self.roads / "manifest.json")

    def test_wrong_wire_compatibility_rule_fails(self):
        altered = dict(self.fence_manifest)
        altered["wire_compatibility_rule"] = "assign recovered chain-link art to every fence"
        # Mutate both the compiled source and packaged copy. Exact byte/JSON
        # equality should pass so this test reaches the authority-rule guard.
        (self.fences / "manifest.json").write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, "compatibility rule"):
            validate(self._write_apk(fence_manifest=altered), self.roads / "manifest.json")


if __name__ == "__main__":
    unittest.main()
