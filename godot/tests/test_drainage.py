import unittest

from godot.tools.build_drainage import drainage_kind, extract_drainage


class IdentityTransformer:
    def transform(self, lon, lat):
        return float(lon), -float(lat)


class DrainageCompilerTests(unittest.TestCase):
    def test_explicit_ditches_drains_and_culverts_are_kept(self):
        features = [
            {
                "type": "Feature", "id": "w10",
                "properties": {"waterway": "ditch", "width": "1.2 m", "intermittent": "yes"},
                "geometry": {"type": "LineString", "coordinates": [[10.0, 10.0], [20.0, 10.0]]},
            },
            {
                "type": "Feature", "id": "w20",
                "properties": {"waterway": "drain"},
                "geometry": {"type": "LineString", "coordinates": [[20.0, 20.0], [30.0, 20.0]]},
            },
            {
                "type": "Feature", "id": "w30",
                "properties": {"waterway": "stream", "tunnel": "culvert", "layer": "-1", "diameter": "0.8"},
                "geometry": {"type": "LineString", "coordinates": [[30.0, 30.0], [40.0, 30.0]]},
            },
            {
                "type": "Feature", "id": "w40",
                "properties": {"waterway": "stream"},
                "geometry": {"type": "LineString", "coordinates": [[40.0, 40.0], [50.0, 40.0]]},
            },
            {
                "type": "Feature", "id": "w50",
                "properties": {"man_made": "culvert", "material": "concrete"},
                "geometry": {"type": "LineString", "coordinates": [[50.0, 50.0], [60.0, 50.0]]},
            },
        ]
        result = extract_drainage(features, IdentityTransformer(), (0.0, 0.0), 64.0)
        self.assertEqual(result["stats"]["features"], 4)
        self.assertEqual(result["stats"]["source_segments"], 4)
        self.assertEqual(result["stats"]["by_kind"], {"culvert": 2, "ditch": 1, "drain": 1})
        self.assertEqual(result["stats"]["explicit_measure_features"], 2)
        records = result["tiles"][(0, 0)]
        self.assertEqual(len(records), 4)
        by_source = {item["source_way"]: item for item in records}
        self.assertEqual(by_source["w10"]["kind"], "ditch")
        self.assertEqual(by_source["w10"]["width_m"], 1.2)
        self.assertEqual(by_source["w10"]["width_source"], "width")
        self.assertEqual(by_source["w30"]["kind"], "culvert")
        self.assertEqual(by_source["w30"]["width_m"], 0.8)
        self.assertEqual(by_source["w30"]["layer"], "-1")
        self.assertEqual(by_source["w50"]["kind"], "culvert")
        self.assertNotIn("w40", by_source)

    def test_generic_stream_is_not_road_drainage_evidence(self):
        self.assertIsNone(drainage_kind({"waterway": "stream"}))
        self.assertEqual(drainage_kind({"waterway": "stream", "tunnel": "culvert"}), "culvert")
        self.assertEqual(drainage_kind({"waterway": "ditch"}), "ditch")
        self.assertEqual(drainage_kind({"waterway": "drain"}), "drain")

    def test_tile_seams_are_deterministic(self):
        features = [{
            "type": "Feature", "id": "w60", "properties": {"waterway": "ditch"},
            "geometry": {"type": "LineString", "coordinates": [[60.0, 5.0], [70.0, 5.0]]},
        }]
        result = extract_drainage(features, IdentityTransformer(), (0.0, 0.0), 64.0)
        self.assertEqual(result["stats"]["tile_pieces"], 2)
        self.assertEqual(result["tiles"][(0, 0)][0]["end"], [64.0, 5.0])
        self.assertEqual(result["tiles"][(1, 0)][0]["start"], [64.0, 5.0])

    def test_duplicate_source_ids_fail_closed(self):
        feature = {
            "type": "Feature", "id": "w70", "properties": {"waterway": "drain"},
            "geometry": {"type": "LineString", "coordinates": [[1.0, 1.0], [5.0, 1.0]]},
        }
        with self.assertRaises(ValueError):
            extract_drainage([feature, feature], IdentityTransformer(), (0.0, 0.0), 64.0)

    def test_invalid_tile_size_fails_closed(self):
        with self.assertRaises(ValueError):
            extract_drainage([], IdentityTransformer(), (0.0, 0.0), 0.0)


if __name__ == "__main__":
    unittest.main()
