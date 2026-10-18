import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, relative):
    path = ROOT / relative
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


road_graph = load_module("road_graph_closed_loop_test", "godot/tools/road_graph.py")
route_pack = load_module("road_route_pack_closed_loop_test", "godot/tools/road_route_pack.py")


class IdentityTransformer:
    def transform(self, x, y):
        return x, y


class ClosedRoadLoopTests(unittest.TestCase):
    def feature(self, junction="roundabout"):
        properties = {"highway": "residential"}
        if junction:
            properties["junction"] = junction
        return {
            "type": "Feature",
            "id": "w42",
            "properties": properties,
            "geometry": {
                "type": "LineString",
                "coordinates": [
                    [0.0, 0.0],
                    [40.0, 0.0],
                    [40.0, -40.0],
                    [0.0, -40.0],
                    [0.0, 0.0],
                ],
            },
            "osm_node_ids": [100, 101, 102, 103, 100],
        }

    def build(self, feature):
        return road_graph.build_network(
            [feature],
            IdentityTransformer(),
            (0.0, 0.0),
            1000.0,
            {"residential": 6.0},
            {"residential": 1},
            lambda _tags: 0,
            {},
        )

    def test_closed_osm_way_is_split_at_real_interior_node(self):
        network = self.build(self.feature())
        self.assertEqual(len(network["edges"]), 2)
        self.assertEqual(set(network["nodes"]), {"osm:100", "osm:102"})
        self.assertFalse(any(edge["from"] == edge["to"] for edge in network["edges"].values()))
        self.assertEqual(sum(len(edge["path"]) - 1 for edge in network["edges"].values()), 4)
        self.assertEqual(sum(edge["length_m"] for edge in network["edges"].values()), 160.0)
        route_pack.build_route_pack(network)

    def test_closed_loop_preserves_source_way_and_direction(self):
        network = self.build(self.feature())
        for edge in network["edges"].values():
            self.assertEqual(edge["source_way"], "w42")
            self.assertEqual(edge["direction"], 1)
            self.assertTrue(edge["id"].startswith("w42:0:osm:"))

    def test_open_way_is_not_artificially_split(self):
        feature = self.feature(junction="")
        feature["geometry"]["coordinates"] = feature["geometry"]["coordinates"][:-1]
        feature["osm_node_ids"] = feature["osm_node_ids"][:-1]
        network = self.build(feature)
        self.assertEqual(len(network["edges"]), 1)
        edge = next(iter(network["edges"].values()))
        self.assertEqual(edge["from"], "osm:100")
        self.assertEqual(edge["to"], "osm:103")


if __name__ == "__main__":
    unittest.main()
