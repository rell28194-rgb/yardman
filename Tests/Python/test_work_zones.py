import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_work_zones import compile_work_zones


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class WorkZoneCompilerTests(unittest.TestCase):
    def test_only_highway_construction_is_retained(self):
        features = [
            {
                "type": "Feature",
                "id": "w100",
                "properties": {
                    "highway": "construction",
                    "construction": "primary",
                    "lanes": "2",
                    "surface": "asphalt",
                    "access": "no",
                },
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[10.0, -10.0], [30.0, -10.0]],
                },
            },
            {
                "type": "Feature",
                "id": "w200",
                "properties": {"highway": "residential"},
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[10.0, -20.0], [30.0, -20.0]],
                },
            },
        ]
        result = compile_work_zones(features, IdentityTransformer(), (0.0, 0.0), 100.0)
        self.assertFalse(result["drivable"])
        self.assertFalse(result["navigation"])
        self.assertTrue(result["geographic_authority"])
        self.assertEqual(result["stats"]["source_ways"], 1)
        self.assertEqual(result["stats"]["source_segments"], 1)
        self.assertEqual(result["stats"]["segments"], 1)
        self.assertEqual(result["stats"]["sectors"], 1)
        record = result["sectors"][0][2][0]
        self.assertEqual(record["source_way"], "w100")
        self.assertEqual(record["construction_class"], "primary")
        self.assertEqual(record["surface"], "asphalt")
        self.assertEqual(record["access"], "no")
        self.assertEqual(record["lanes"], 2)
        self.assertAlmostEqual(record["width_m"], 6.4)
        self.assertEqual(record["width_source"], "osm:lanes (lane width inferred)")

    def test_tile_boundaries_are_split_without_losing_identity(self):
        feature = {
            "type": "Feature",
            "id": "w300",
            "properties": {"highway": "construction", "construction": "service"},
            "geometry": {
                "type": "LineString",
                "coordinates": [[90.0, -10.0], [110.0, -10.0]],
            },
        }
        result = compile_work_zones([feature], IdentityTransformer(), (0.0, 0.0), 100.0)
        self.assertEqual(result["stats"]["source_ways"], 1)
        self.assertEqual(result["stats"]["source_segments"], 1)
        self.assertEqual(result["stats"]["segments"], 2)
        self.assertEqual(result["stats"]["sectors"], 2)
        records = [sector[2][0] for sector in result["sectors"]]
        self.assertTrue(all(record["source_way"] == "w300" for record in records))
        self.assertTrue(all(record["construction_class"] == "service" for record in records))

    def test_invalid_tile_size_fails_closed(self):
        with self.assertRaises(ValueError):
            compile_work_zones([], IdentityTransformer(), (0.0, 0.0), 0.0)


if __name__ == "__main__":
    unittest.main()
