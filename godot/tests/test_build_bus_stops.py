import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_bus_stops import _is_bus_stop, extract_bus_stops


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class BusStopCompilerTest(unittest.TestCase):
    def point(self, fid, tags, x, y):
        return {"id": fid, "properties": tags, "geometry": {"type": "Point", "coordinates": [x, y]}}

    def test_only_explicit_bus_stop_point_semantics_are_compiled(self):
        features = [
            self.point("h", {"highway": "bus_stop", "shelter": "yes"}, 10, 20),
            self.point("p", {"public_transport": "platform", "bus": "yes", "bench": "yes"}, 30, 40),
            self.point("platform-no-bus", {"public_transport": "platform"}, 50, 60),
            self.point("random", {"amenity": "shelter"}, 70, 80),
        ]
        result = extract_bus_stops(features, IdentityTransformer(), (0, 0), 4096.0)
        self.assertEqual(result["stats"]["features"], 2)
        records = [row for rows in result["tiles"].values() for row in rows]
        self.assertEqual({r["source_node"] for r in records}, {"h", "p"})
        highway = next(r for r in records if r["source_node"] == "h")
        platform = next(r for r in records if r["source_node"] == "p")
        self.assertEqual(highway["kind"], "highway=bus_stop")
        self.assertEqual(highway["shelter"], "yes")
        self.assertEqual(highway["bench"], "unspecified")
        self.assertEqual(platform["kind"], "public_transport=platform+bus")
        self.assertEqual(platform["bench"], "yes")
        self.assertEqual(platform["shelter"], "unspecified")

    def test_optional_metadata_is_preserved_without_inference(self):
        feature = self.point(
            "meta",
            {"highway": "bus_stop", "name": "Half Way Tree", "operator": "JUTC", "network": "Kingston", "ref": "12", "wheelchair": "yes"},
            100,
            200,
        )
        result = extract_bus_stops([feature], IdentityTransformer(), (0, 0), 4096.0)
        record = next(iter(result["tiles"].values()))[0]
        self.assertEqual(record["name"], "Half Way Tree")
        self.assertEqual(record["operator"], "JUTC")
        self.assertEqual(record["network"], "Kingston")
        self.assertEqual(record["ref"], "12")
        self.assertEqual(record["wheelchair"], "yes")
        self.assertEqual(record["shelter"], "unspecified")

    def test_tile_ownership_uses_canonical_world_metres(self):
        feature = self.point("tile", {"highway": "bus_stop"}, 4096.1, -4096.1)
        result = extract_bus_stops([feature], IdentityTransformer(), (0, 0), 4096.0)
        self.assertIn((1, 1), result["tiles"])
        record = result["tiles"][(1, 1)][0]
        self.assertEqual(record["position"], [4096.1, 4096.1])

    def test_duplicate_identity_and_invalid_tile_size_fail_closed(self):
        feature = self.point("dup", {"highway": "bus_stop"}, 1, 1)
        with self.assertRaises(ValueError):
            extract_bus_stops([feature, feature], IdentityTransformer(), (0, 0), 4096.0)
        with self.assertRaises(ValueError):
            extract_bus_stops([], IdentityTransformer(), (0, 0), 0.0)
        with self.assertRaises(ValueError):
            extract_bus_stops([], IdentityTransformer(), (0, 0), math.inf)

    def test_semantics_helper(self):
        self.assertTrue(_is_bus_stop({"highway": "bus_stop"}))
        self.assertTrue(_is_bus_stop({"public_transport": "platform", "bus": "designated"}))
        self.assertFalse(_is_bus_stop({"public_transport": "platform"}))
        self.assertFalse(_is_bus_stop({"highway": "platform", "bus": "yes"}))


if __name__ == "__main__":
    unittest.main()
