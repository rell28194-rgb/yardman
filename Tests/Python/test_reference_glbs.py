import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "godot/tools/validate_reference_glbs.py"
SPEC = importlib.util.spec_from_file_location("validate_reference_glbs", TOOL)
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MOD)


def make_glb(path: Path, *, low=(0.0, 0.0, 0.0), high=(1.0, 2.0, 3.0), vertex_count=3, index_count=3):
    doc = {
        "asset": {"version": "2.0"},
        "accessors": [
            {"componentType": 5126, "count": vertex_count, "type": "VEC3", "min": list(low), "max": list(high)},
            {"componentType": 5123, "count": index_count, "type": "SCALAR"},
        ],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
    }
    payload = json.dumps(doc, separators=(",", ":")).encode()
    payload += b" " * ((4 - len(payload) % 4) % 4)
    total = 12 + 8 + len(payload)
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, total) + struct.pack("<II", len(payload), 0x4E4F534A) + payload)


class ReferenceGlbTests(unittest.TestCase):
    def test_valid_glb_reports_geometry_and_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "valid.glb"
            make_glb(path)
            result = MOD.validate_glb(path)
            self.assertEqual(result["vertices"], 3)
            self.assertEqual(result["triangles_declared"], 1)
            self.assertEqual(result["extents_m"], [1.0, 2.0, 3.0])

    def test_scale_explosion_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "huge.glb"
            make_glb(path, high=(250.0, 1.0, 1.0))
            with self.assertRaisesRegex(MOD.ValidationError, "exceeds"):
                MOD.validate_glb(path, max_extent_m=100.0)

    def test_invalid_triangle_indices_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bad.glb"
            make_glb(path, index_count=4)
            with self.assertRaisesRegex(MOD.ValidationError, "divisible by 3"):
                MOD.validate_glb(path)

    def test_directory_requires_models(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(MOD.ValidationError, "no GLB"):
                MOD.validate_directory(Path(temp))


if __name__ == "__main__":
    unittest.main()
