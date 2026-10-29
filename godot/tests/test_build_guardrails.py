import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_guardrails import _finite_height, extract_guardrails


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class GuardRailCompilerTest(unittest.TestCase):
    def feature(self, fid, tags, coords):
        return {"id": fid, "properties": tags, "geometry": {"type": "LineString", "coordinates": coords}}

    def test_only_explicit_guard_rail_is_compiled(self):
        features = [
            self.feature("rail", {"barrier": "guard_rail", "material": "steel", "height": "0.75 m"}, [[0, 0], [80, 0]]),
            self.feature("fence", {"barrier": "fence", "material": "steel"}, [[0, 10], [80, 10]]),
            self.feature("wall", {"barrier": "retaining_wall"}, [[0, 20], [80, 20]]),
        ]
        result = extract_guardrails(features, IdentityTransformer(), (0, 0), 4096.0)
        self.assertEqual(result["stats"]["features"], 1)
        self.assertEqual(result["stats"]["source_segments"], 1)
        records = [row for rows in result["tiles"].values() for row in rows]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["source_way"], "rail")
        self.assertEqual(records[0]["barrier"], "guard_rail")
        self.assertEqual(records[0]["material"], "steel")
        self.assertEqual(records[0]["height_m"], 0.75)

    def test_segment_crossing_tile_is_split_without_moving_world_geometry(self):
        feature = self.feature("cross", {"barrier": "guard_rail"}, [[4090, 0], [4105, 0]])
        result = extract_guardrails([feature], IdentityTransformer(), (0, 0), 4096.0)
        self.assertEqual(result["stats"]["tiles"], 2)
        self.assertEqual(result["stats"]["tile_pieces"], 2)
        records = [row for _, rows in sorted(result["tiles"].items()) for row in rows]
        self.assertEqual(records[0]["start"][0], 4090.0)
        self.assertAlmostEqual(records[0]["end"][0], 4096.0, places=3)
        self.assertAlmostEqual(records[1]["start"][0], 4096.0, places=3)
        self.assertEqual(records[1]["end"][0], 4105.0)

    def test_optional_source_metadata_is_preserved_without_inference(self):
        feature = self.feature(
            "meta",
            {"barrier": "guard_rail", "direction": "forward", "colour": "silver", "reflective": "yes"},
            [[0, 0], [10, 0]],
        )
        result = extract_guardrails([feature], IdentityTransformer(), (0, 0), 4096.0)
        record = next(iter(result["tiles"].values()))[0]
        self.assertEqual(record["direction"], "forward")
        self.assertEqual(record["colour"], "silver")
        self.assertEqual(record["reflective"], "yes")
        self.assertEqual(record["material"], "unspecified")

    def test_height_and_duplicate_identity_fail_closed(self):
        self.assertEqual(_finite_height({"height": "1.1m"}), 1.1)
        self.assertIsNone(_finite_height({"height": "unknown"}))
        self.assertIsNone(_finite_height({"height": "20m"}))
        feature = self.feature("dup", {"barrier": "guard_rail"}, [[0, 0], [10, 0]])
        with self.assertRaises(ValueError):
            extract_guardrails([feature, feature], IdentityTransformer(), (0, 0), 4096.0)

    def test_invalid_tile_size_fails(self):
        with self.assertRaises(ValueError):
            extract_guardrails([], IdentityTransformer(), (0, 0), 0.0)
        with self.assertRaises(ValueError):
            extract_guardrails([], IdentityTransformer(), (0, 0), math.inf)


if __name__ == "__main__":
    unittest.main()
