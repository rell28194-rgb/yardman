import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_fences import _finite_height, _wire_compatible, extract_fences


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class FenceCompilerTest(unittest.TestCase):
    def feature(self, fid, tags, coords):
        return {"id": fid, "properties": tags, "geometry": {"type": "LineString", "coordinates": coords}}

    def test_only_barrier_fence_is_compiled_and_style_is_strict(self):
        features = [
            self.feature("wire", {"barrier": "fence", "fence_type": "chain_link", "height": "2.4 m"}, [[0, 0], [80, 0]]),
            self.feature("generic", {"barrier": "fence"}, [[0, 10], [30, 10]]),
            self.feature("wall", {"barrier": "wall", "material": "metal"}, [[0, 20], [50, 20]]),
        ]
        result = extract_fences(features, IdentityTransformer(), (0, 0), 4096.0)
        self.assertEqual(result["stats"]["features"], 2)
        self.assertEqual(result["stats"]["wire_compatible_features"], 1)
        records = [r for rows in result["tiles"].values() for r in rows]
        wire = next(r for r in records if r["source_way"] == "wire")
        generic = next(r for r in records if r["source_way"] == "generic")
        self.assertTrue(wire["wire_compatible"])
        self.assertEqual(wire["height_m"], 2.4)
        self.assertFalse(generic["wire_compatible"])
        self.assertEqual(generic["fence_type"], "unspecified")

    def test_segment_crossing_tile_is_split_without_changing_world_coordinates(self):
        feature = self.feature("cross", {"barrier": "fence", "material": "steel"}, [[4090, 0], [4105, 0]])
        result = extract_fences([feature], IdentityTransformer(), (0, 0), 4096.0)
        self.assertEqual(result["stats"]["features"], 1)
        self.assertEqual(result["stats"]["tiles"], 2)
        self.assertEqual(result["stats"]["tile_pieces"], 2)
        records = [r for _, rows in sorted(result["tiles"].items()) for r in rows]
        self.assertEqual(records[0]["start"][0], 4090.0)
        self.assertAlmostEqual(records[0]["end"][0], 4096.0, places=3)
        self.assertAlmostEqual(records[1]["start"][0], 4096.0, places=3)
        self.assertEqual(records[1]["end"][0], 4105.0)

    def test_style_and_height_helpers_reject_implicit_or_invalid_claims(self):
        self.assertTrue(_wire_compatible({"barrier": "fence", "barbed_wire": "yes"}))
        self.assertTrue(_wire_compatible({"barrier": "fence", "material": "galvanised_steel"}))
        self.assertFalse(_wire_compatible({"barrier": "fence", "fence_type": "wood"}))
        self.assertFalse(_wire_compatible({"barrier": "fence"}))
        self.assertIsNone(_finite_height({"height": "unknown"}))
        self.assertIsNone(_finite_height({"height": "200m"}))
        self.assertEqual(_finite_height({"height": "1.8 m"}), 1.8)

    def test_invalid_tile_size_fails(self):
        with self.assertRaises(ValueError):
            extract_fences([], IdentityTransformer(), (0, 0), 0.0)
        with self.assertRaises(ValueError):
            extract_fences([], IdentityTransformer(), (0, 0), math.inf)


if __name__ == "__main__":
    unittest.main()
