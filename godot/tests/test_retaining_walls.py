import unittest

from godot.tools.build_retaining_walls import extract_retaining_walls


class IdentityTransformer:
    def transform(self, lon, lat):
        # Compiler converts projected northing back to south-positive Z.
        return float(lon), -float(lat)


class RetainingWallCompilerTests(unittest.TestCase):
    def test_only_explicit_retaining_walls_become_geometry(self):
        features = [
            {
                "type": "Feature",
                "id": "w100",
                "properties": {
                    "barrier": "retaining_wall",
                    "height": "2.5 m",
                    "material": "stone",
                },
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[10.0, 10.0], [20.0, 10.0], [30.0, 10.0]],
                },
            },
            {
                "type": "Feature",
                "id": "w200",
                "properties": {"barrier": "wall"},
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[10.0, 20.0], [20.0, 20.0]],
                },
            },
        ]
        result = extract_retaining_walls(features, IdentityTransformer(), (0.0, 0.0), 64.0)
        self.assertEqual(result["stats"]["features"], 1)
        self.assertEqual(result["stats"]["source_segments"], 2)
        self.assertEqual(result["stats"]["explicit_height_features"], 1)
        self.assertEqual(result["stats"]["by_material"], {"stone": 1})
        records = result["tiles"][(0, 0)]
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["barrier"], "retaining_wall")
        self.assertEqual(records[0]["height_m"], 2.5)
        self.assertEqual(records[0]["material"], "stone")
        self.assertEqual(records[0]["start"], [10.0, 10.0])
        self.assertEqual(records[1]["end"], [30.0, 10.0])

    def test_absent_or_invalid_height_stays_unspecified(self):
        features = [{
            "type": "Feature",
            "id": "w300",
            "properties": {"barrier": "retaining_wall", "height": "unknown"},
            "geometry": {"type": "LineString", "coordinates": [[1.0, 1.0], [5.0, 1.0]]},
        }]
        result = extract_retaining_walls(features, IdentityTransformer(), (0.0, 0.0), 64.0)
        record = result["tiles"][(0, 0)][0]
        self.assertNotIn("height_m", record)
        self.assertEqual(result["stats"]["explicit_height_features"], 0)

    def test_duplicate_source_ids_fail_closed(self):
        feature = {
            "type": "Feature",
            "id": "w400",
            "properties": {"barrier": "retaining_wall"},
            "geometry": {"type": "LineString", "coordinates": [[1.0, 1.0], [5.0, 1.0]]},
        }
        with self.assertRaises(ValueError):
            extract_retaining_walls([feature, feature], IdentityTransformer(), (0.0, 0.0), 64.0)

    def test_invalid_tile_size_fails_closed(self):
        with self.assertRaises(ValueError):
            extract_retaining_walls([], IdentityTransformer(), (0.0, 0.0), 0.0)


if __name__ == "__main__":
    unittest.main()
