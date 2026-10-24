import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from road_graph import BRIDGE_FLAG, bridge_deck_profile, build_network


class Identity:
    def transform(self, x, y):
        return x, -y


class ValleySampler:
    def __init__(self):
        self.conform_calls = 0

    def __call__(self, x, z):
        if x <= 0.01 or x >= 19.99:
            return 10.0
        return 0.0

    def conform_polygon(self, polygon):
        self.conform_calls += 1
        conformed = []
        for point in polygon:
            values = list(point)
            values[1] = self(values[0], values[2])
            conformed.append(tuple(values))
        return [conformed]


def road_flags(tags):
    value = str(tags.get("bridge", "")).strip().lower()
    return BRIDGE_FLAG if value not in {"", "no", "0", "false"} else 0


def feature(bridge=False):
    properties = {"highway": "primary"}
    if bridge:
        properties.update({"bridge": "yes", "layer": "1"})
    return {
        "id": "w1",
        "properties": properties,
        "geometry": {"type": "LineString", "coordinates": [[0, 0], [10, 0], [20, 0]]},
        "osm_node_ids": [1, 2, 3],
    }


def compile_feature(item, sampler):
    return build_network(
        [item], Identity(), (0, 0), 100.0,
        {"primary": 7.2}, {"primary": 0}, road_flags, {}, sampler,
    )


class BridgeDeckProfileTests(unittest.TestCase):
    def test_bridge_profile_preserves_endpoints_and_clears_valley(self):
        raw = [(0.0, 10.0, 0.0), (10.0, 0.0, 0.0), (20.0, 10.0, 0.0)]
        profiled = bridge_deck_profile(raw)
        self.assertEqual(profiled[0], raw[0])
        self.assertEqual(profiled[-1], raw[-1])
        self.assertGreater(profiled[1][1], 10.3)

    def test_bridge_ribbon_is_not_redraped_onto_terrain(self):
        sampler = ValleySampler()
        result = compile_feature(feature(bridge=True), sampler)
        edge = next(iter(result["edges"].values()))
        self.assertTrue(edge["bridge"])
        self.assertTrue(edge["bridge_profile_inferred"])
        self.assertEqual(edge["path"][0][1], 10.0)
        self.assertEqual(edge["path"][-1][1], 10.0)
        self.assertGreater(edge["path"][1][1], 10.3)
        self.assertEqual(sampler.conform_calls, 0)
        surface_points = [
            point
            for records in result["tiles"].values()
            for record in records
            for point in record[11]
        ]
        midpoint_points = [point for point in surface_points if abs(point[0] - 10.0) < 0.001]
        self.assertTrue(midpoint_points)
        self.assertTrue(all(point[1] > 10.3 for point in midpoint_points))

    def test_ordinary_road_still_conforms_to_terrain(self):
        sampler = ValleySampler()
        result = compile_feature(feature(bridge=False), sampler)
        edge = next(iter(result["edges"].values()))
        self.assertFalse(edge["bridge"])
        self.assertFalse(edge["bridge_profile_inferred"])
        self.assertGreater(sampler.conform_calls, 0)


if __name__ == "__main__":
    unittest.main()
