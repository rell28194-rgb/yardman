import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from validate_apk import (  # noqa: E402
    DRAINAGE_PLACEMENT_RULE,
    DRAINAGE_PURPOSE,
    _validate_packaged_drainage,
)


class PackagedDrainageValidationTests(unittest.TestCase):
    def _fixture(self, root: Path):
        roads = root / "roads"
        drainage = roads / "drainage"
        drainage.mkdir(parents=True)
        source_manifest = roads / "manifest.json"
        source_manifest.write_text("{}")
        tile_payload = {
            "tile": [0, 0],
            "drainage": [
                {
                    "source_way": "w10",
                    "line": 0,
                    "segment": 0,
                    "kind": "ditch",
                    "waterway": "ditch",
                    "start": [10.0, 10.0],
                    "end": [20.0, 10.0],
                    "layer": "0",
                },
                {
                    "source_way": "w20",
                    "line": 0,
                    "segment": 0,
                    "kind": "culvert",
                    "waterway": "stream",
                    "start": [30.0, 10.0],
                    "end": [35.0, 10.0],
                    "layer": "-1",
                    "portal_start": True,
                    "portal_end": True,
                },
            ],
        }
        manifest = {
            "format": 1,
            "purpose": DRAINAGE_PURPOSE,
            "source": "test Jamaica OSM",
            "source_sha256": "same-source",
            "attribution": "test",
            "crs": "EPSG:3448",
            "axis": "X=east, Z=south, metres",
            "tile_size": 4096.0,
            "placement_rule": DRAINAGE_PLACEMENT_RULE,
            "bounds": [0.0, 0.0, 35.0, 10.0],
            "stats": {
                "features": 2,
                "source_segments": 2,
                "tile_pieces": 2,
                "tiles": 1,
                "explicit_measure_features": 0,
                "by_kind": {"culvert": 1, "ditch": 1},
                "by_waterway": {"ditch": 1, "stream": 1},
            },
            "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "records": 2}],
        }
        (drainage / "manifest.json").write_text(json.dumps(manifest))
        (drainage / "tile_0_0.json").write_text(json.dumps(tile_payload))
        return source_manifest, manifest, tile_payload

    def _apk(self, path: Path, manifest: dict, tile_payload: dict, include_tile: bool = True):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("assets/data/roads/drainage/manifest.json", json.dumps(manifest))
            if include_tile:
                archive.writestr("assets/data/roads/drainage/tile_0_0.json", json.dumps(tile_payload))

    def test_valid_registered_drainage_returns_packaging_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_manifest, manifest, tile_payload = self._fixture(root)
            apk = root / "fixture.zip"
            self._apk(apk, manifest, tile_payload)
            with zipfile.ZipFile(apk) as archive:
                proof = _validate_packaged_drainage(
                    archive,
                    set(archive.namelist()),
                    source_manifest,
                    {"crs": "EPSG:3448", "source_sha256": "same-source"},
                )
            self.assertEqual(proof["drainage_features"], 2)
            self.assertEqual(proof["drainage_tiles"], 1)
            self.assertEqual(proof["culvert_features"], 1)
            self.assertEqual(proof["ditch_features"], 1)
            self.assertEqual(proof["drain_features"], 0)

    def test_missing_packaged_tile_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_manifest, manifest, tile_payload = self._fixture(root)
            apk = root / "fixture.zip"
            self._apk(apk, manifest, tile_payload, include_tile=False)
            with zipfile.ZipFile(apk) as archive:
                with self.assertRaisesRegex(ValueError, "drainage tile was omitted"):
                    _validate_packaged_drainage(
                        archive,
                        set(archive.namelist()),
                        source_manifest,
                        {"crs": "EPSG:3448", "source_sha256": "same-source"},
                    )

    def test_source_registration_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_manifest, manifest, tile_payload = self._fixture(root)
            apk = root / "fixture.zip"
            self._apk(apk, manifest, tile_payload)
            with zipfile.ZipFile(apk) as archive:
                with self.assertRaisesRegex(ValueError, "source registration differs"):
                    _validate_packaged_drainage(
                        archive,
                        set(archive.namelist()),
                        source_manifest,
                        {"crs": "EPSG:3448", "source_sha256": "different-source"},
                    )

    def test_absent_compiled_drainage_is_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            roads = root / "roads"
            roads.mkdir()
            source_manifest = roads / "manifest.json"
            source_manifest.write_text("{}")
            apk = root / "fixture.zip"
            with zipfile.ZipFile(apk, "w"):
                pass
            with zipfile.ZipFile(apk) as archive:
                proof = _validate_packaged_drainage(archive, set(), source_manifest, {})
            self.assertEqual(proof["drainage_features"], 0)
            self.assertEqual(proof["drainage_tiles"], 0)


if __name__ == "__main__":
    unittest.main()
