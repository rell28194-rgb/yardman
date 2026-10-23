import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from roadside_point_compile import compile_points, classify_point


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class RoadsidePointCompilerTests(unittest.TestCase):
    def setUp(self):
        self.transformer = IdentityTransformer()

    def _point(self, identifier, lon, lat, **properties):
        return {
            "type": "Feature",
            "id": identifier,
            "properties": properties,
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
        }

    def test_classification_is_explicit_only(self):
        self.assertEqual(classify_point({"highway": "street_lamp"}), "street_lamp")
        self.assertEqual(classify_point({"highway": "bus_stop", "shelter": "yes"}), "bus_shelter")
        self.assertEqual(classify_point({"highway": "bus_stop", "shelter": "TRUE"}), "bus_shelter")
        self.assertIsNone(classify_point({"highway": "bus_stop"}))
        self.assertIsNone(classify_point({"highway": "bus_stop", "shelter": "no"}))
        self.assertIsNone(classify_point({"highway": "traffic_signals"}))

    def test_only_source_authorized_points_are_compiled(self):
        features = [
            self._point("n1", -76.7936, 17.9714, highway="street_lamp", lamp_mount="bent_mast"),
            self._point("n2", -76.7935, 17.9714, highway="bus_stop", shelter="yes", name="Test Stop"),
            self._point("n3", -76.7934, 17.9714, highway="bus_stop", shelter="no"),
            self._point("n4", -76.7933, 17.9714, highway="traffic_signals"),
            {
                "type": "Feature",
                "id": "w5",
                "properties": {"highway": "street_lamp"},
                "geometry": {"type": "LineString", "coordinates": [[-76.79, 17.97], [-76.78, 17.97]]},
            },
        ]
        result = compile_points(features, tile_size=4096.0, transformer=self.transformer)
        self.assertTrue(result["geographic_authority"])
        self.assertFalse(result["routing"])
        self.assertFalse(result["navigation"])
        self.assertFalse(result["collision"])
        self.assertFalse(result["inferred_spacing"])
        self.assertEqual(result["stats"]["points"], 2)
        self.assertEqual(result["stats"]["by_kind"], {"bus_shelter": 1, "street_lamp": 1})
        records = [record for sector in result["sectors"] for record in sector[2]]
        self.assertEqual({record["id"] for record in records}, {"n1", "n2"})
        lamp = next(record for record in records if record["id"] == "n1")
        stop = next(record for record in records if record["id"] == "n2")
        self.assertEqual(lamp["kind"], "street_lamp")
        self.assertEqual(lamp["source_tags"]["lamp_mount"], "bent_mast")
        self.assertEqual(stop["kind"], "bus_shelter")
        self.assertEqual(stop["source_tags"]["shelter"], "yes")
        self.assertEqual(stop["source_tags"]["name"], "Test Stop")
        self.assertEqual(lamp["elevation_source"], "runtime-terrain-grounded")

    def test_duplicate_source_identity_is_not_double_placed(self):
        feature = self._point("n100", -76.7936, 17.9714, highway="street_lamp")
        result = compile_points([feature, dict(feature)], tile_size=4096.0, transformer=self.transformer)
        self.assertEqual(result["stats"]["points"], 1)
        records = [record for sector in result["sectors"] for record in sector[2]]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["id"], "n100")

    def test_nested_tags_are_supported_without_broadening_authority(self):
        feature = {
            "type": "Feature",
            "id": "n200",
            "properties": {"tags": {"highway": "bus_stop", "shelter": "1", "bus": "yes"}},
            "geometry": {"type": "Point", "coordinates": [-76.7936, 17.9714]},
        }
        result = compile_points([feature], tile_size=4096.0, transformer=self.transformer)
        self.assertEqual(result["stats"]["points"], 1)
        record = result["sectors"][0][2][0]
        self.assertEqual(record["kind"], "bus_shelter")
        self.assertEqual(record["source_tags"]["bus"], "yes")

    def test_height_sampler_is_recorded_without_geometry_inference(self):
        feature = self._point("n300", -76.7936, 17.9714, highway="street_lamp")
        result = compile_points(
            [feature], tile_size=4096.0,
            height_sampler=lambda _x, _z: 123.456,
            transformer=self.transformer,
        )
        record = result["sectors"][0][2][0]
        self.assertAlmostEqual(record["position"][1], 123.456)
        self.assertEqual(record["elevation_source"], "DEM")
        self.assertFalse(result["inferred_spacing"])

    def test_invalid_tile_size_fails_closed(self):
        with self.assertRaises(ValueError):
            compile_points([], tile_size=0.0, transformer=self.transformer)
        with self.assertRaises(ValueError):
            compile_points([], tile_size=float("nan"), transformer=self.transformer)


if __name__ == "__main__":
    unittest.main()
