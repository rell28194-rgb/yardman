import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_streetlights import _finite_height, extract_streetlights


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class StreetlightCompilerTest(unittest.TestCase):
    def feature(self, fid, tags, coords, geometry_type="Point"):
        return {
            "id": fid,
            "properties": tags,
            "geometry": {"type": geometry_type, "coordinates": coords},
        }

    def test_only_explicit_street_lamp_points_are_compiled(self):
        features = [
            self.feature(
                "lamp-a",
                {"highway": "street_lamp", "height": "8 m", "lamp_mount": "straight_mast", "support": "pole"},
                [100.0, 200.0],
            ),
            self.feature("signals", {"highway": "traffic_signals"}, [120.0, 220.0]),
            self.feature("road-way", {"highway": "street_lamp"}, [[0, 0], [1, 1]], "LineString"),
        ]
        result = extract_streetlights(features, IdentityTransformer(), (0.0, 0.0), 4096.0)
        self.assertEqual(result["stats"]["features"], 1)
        self.assertEqual(result["stats"]["tiles"], 1)
        record = next(iter(result["tiles"].values()))[0]
        self.assertEqual(record["source_node"], "lamp-a")
        self.assertEqual(record["position"], [100.0, -200.0])
        self.assertEqual(record["height_m"], 8.0)
        self.assertEqual(record["lamp_mount"], "straight_mast")
        self.assertEqual(record["support"], "pole")

    def test_tile_ownership_uses_canonical_world_metres(self):
        features = [
            self.feature("east", {"highway": "street_lamp"}, [4096.1, 0.0]),
            self.feature("west", {"highway": "street_lamp"}, [-0.1, 0.0]),
            self.feature("south", {"highway": "street_lamp"}, [0.0, -4096.1]),
        ]
        result = extract_streetlights(features, IdentityTransformer(), (0.0, 0.0), 4096.0)
        self.assertIn((1, 0), result["tiles"])
        self.assertIn((-1, 0), result["tiles"])
        self.assertIn((0, 1), result["tiles"])
        self.assertEqual(result["stats"]["features"], 3)

    def test_optional_metadata_is_preserved_without_inference(self):
        features = [
            self.feature(
                "typed",
                {
                    "highway": "street_lamp",
                    "direction": "270",
                    "lamp_type": "LED",
                    "light:colour": "warm_white",
                    "manufacturer": "Example",
                },
                [1.0, 1.0],
            ),
            self.feature("plain", {"highway": "street_lamp"}, [2.0, 2.0]),
        ]
        result = extract_streetlights(features, IdentityTransformer(), (0.0, 0.0), 4096.0)
        records = {r["source_node"]: r for rows in result["tiles"].values() for r in rows}
        self.assertEqual(records["typed"]["direction"], "270")
        self.assertEqual(records["typed"]["lamp_type"], "LED")
        self.assertEqual(records["typed"]["light_colour"], "warm_white")
        self.assertEqual(records["typed"]["manufacturer"], "Example")
        self.assertEqual(records["plain"]["lamp_mount"], "unspecified")
        self.assertEqual(records["plain"]["support"], "unspecified")
        self.assertNotIn("height_m", records["plain"])

    def test_height_and_duplicate_identity_fail_closed(self):
        self.assertEqual(_finite_height({"height": "12m"}), 12.0)
        self.assertIsNone(_finite_height({"height": "unknown"}))
        self.assertIsNone(_finite_height({"height": "100m"}))
        duplicate = [
            self.feature("same", {"highway": "street_lamp"}, [1.0, 1.0]),
            self.feature("same", {"highway": "street_lamp"}, [2.0, 2.0]),
        ]
        with self.assertRaises(ValueError):
            extract_streetlights(duplicate, IdentityTransformer(), (0.0, 0.0), 4096.0)

    def test_invalid_tile_size_fails(self):
        with self.assertRaises(ValueError):
            extract_streetlights([], IdentityTransformer(), (0.0, 0.0), 0.0)
        with self.assertRaises(ValueError):
            extract_streetlights([], IdentityTransformer(), (0.0, 0.0), math.inf)


if __name__ == "__main__":
    unittest.main()
