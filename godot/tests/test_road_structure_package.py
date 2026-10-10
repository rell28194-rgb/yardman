import json
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_road_structures import compile_structures
from build_tunnel_portals import compile_portals
from validate_apk import validate
from validate_road_structures import validate_root
from test_road_structures import write_dataset


class RoadStructurePackageTests(unittest.TestCase):
    def _dataset(self, root):
        write_dataset(root)
        manifest = json.loads((root / "manifest.json").read_text())
        manifest["stats"] = {"graph_edges": 3}
        (root / "manifest.json").write_text(json.dumps(manifest))
        compile_structures(root)
        compile_portals(root)

    def _apk(self, root, destination, omit=None, mutate=None):
        with zipfile.ZipFile(destination, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            archive.writestr("resources.arsc", b"resources")
            elf = bytearray(20)
            elf[:4] = b"\x7fELF"
            struct.pack_into("<H", elf, 18, 183)
            archive.writestr("lib/arm64-v8a/libgodot_android.so", elf)
            for path in root.rglob("*.json"):
                relative = path.relative_to(root).as_posix()
                if relative == omit:
                    continue
                payload = path.read_bytes()
                if relative == mutate:
                    value = json.loads(payload)
                    value["tunnels"][0]["a"][1] += 0.5
                    payload = json.dumps(value).encode()
                archive.writestr("assets/data/roads/" + relative, payload)
            # Package verification also requires the real graph's full address
            # space. Empty fixture partitions stand in for those unrelated files.
            for kind in ("nodes", "edges"):
                for index in range(1, 256):
                    archive.writestr(f"assets/data/roads/graph/{kind}_{index:02x}.json", b"{}")

    def test_package_contains_matching_corridors_and_outer_portals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "roads"
            root.mkdir()
            self._dataset(root)
            apk = Path(tmp) / "game.apk"
            self._apk(root, apk)
            result = validate(apk, root / "manifest.json")
            self.assertEqual(result["bridge_edges"], 1)
            self.assertEqual(result["profiled_tunnel_edges"], 1)
            self.assertEqual(result["tunnel_portals"], 2)
            self.assertEqual(result["tunnel_shell_segments"], 2)

    def test_export_cannot_silently_omit_portal_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "roads"
            root.mkdir()
            self._dataset(root)
            apk = Path(tmp) / "game.apk"
            self._apk(root, apk, omit="tunnel_portals/manifest.json")
            with self.assertRaisesRegex(ValueError, "Missing APK road structure"):
                validate(apk, root / "manifest.json")

    def test_export_cannot_silently_omit_tunnel_shells(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "roads"
            root.mkdir()
            self._dataset(root)
            apk = Path(tmp) / "game.apk"
            self._apk(root, apk, omit="structures/tile_0_0.json")
            with self.assertRaisesRegex(ValueError, "Missing APK road structure"):
                validate(apk, root / "manifest.json")

    def test_export_must_include_the_tested_structure_geometry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "roads"
            root.mkdir()
            self._dataset(root)
            apk = Path(tmp) / "game.apk"
            self._apk(root, apk, mutate="structures/tile_0_0.json")
            with self.assertRaisesRegex(ValueError, "differs from validated source"):
                validate(apk, root / "manifest.json")

    def test_data_gate_detects_full_axis_spanning_another_tile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._dataset(root)
            path = root / "structures/tile_0_0.json"
            payload = json.loads(path.read_text())
            payload["tunnels"][0]["b"][0] = 130.0
            path.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "escapes its owning tile"):
                validate_root(root)


if __name__ == "__main__":
    unittest.main()
