import importlib.util
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "godot" / "tools" / "road_route_pack.py"
spec = importlib.util.spec_from_file_location("road_route_pack", MODULE_PATH)
road_route_pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(road_route_pack)


class RoutePackTests(unittest.TestCase):
    def golden_network(self):
        return {
            "nodes": {
                "osm:1": {"id": "osm:1", "position": (0.0, 0.0, 0.0)},
                "osm:2": {"id": "osm:2", "position": (10.0, 1.0, 0.0)},
            },
            "edges": {
                "w1:0:osm:1:osm:2": {
                    "id": "w1:0:osm:1:osm:2",
                    "from": "osm:1",
                    "to": "osm:2",
                    "length_m": 10.0,
                    "class_id": 2,
                    "direction": 1,
                    "speed_limit_mps": 13.5,
                    "flags": 3,
                }
            },
        }

    def test_python_writer_matches_cross_language_golden_bytes(self):
        payload = road_route_pack.build_route_pack(self.golden_network())
        golden_hex = (ROOT / "Tests" / "Fixtures" / "route_pack_v1.hex").read_text().strip()
        self.assertEqual(payload.hex(), golden_hex)
        self.assertEqual(len(payload), 126)

    def test_pack_order_is_independent_of_dictionary_insertion(self):
        network = self.golden_network()
        reversed_network = {
            "nodes": dict(reversed(list(network["nodes"].items()))),
            "edges": dict(reversed(list(network["edges"].items()))),
        }
        self.assertEqual(
            road_route_pack.build_route_pack(network),
            road_route_pack.build_route_pack(reversed_network),
        )

    def test_unknown_speed_is_encoded_as_zero_without_changing_identity(self):
        network = self.golden_network()
        edge = network["edges"]["w1:0:osm:1:osm:2"]
        edge["speed_limit_mps"] = None
        payload = road_route_pack.build_route_pack(network)
        edge_base = road_route_pack.HEADER.size + 2 * road_route_pack.NODE.size
        speed = struct.unpack_from("<f", payload, edge_base + 20)[0]
        self.assertEqual(speed, 0.0)
        self.assertIn(b"w1:0:osm:1:osm:2", payload)

    def test_invalid_topology_and_non_finite_values_fail_closed(self):
        network = self.golden_network()
        network["edges"]["w1:0:osm:1:osm:2"]["to"] = "missing"
        with self.assertRaises(ValueError):
            road_route_pack.build_route_pack(network)

        network = self.golden_network()
        network["nodes"]["osm:2"]["position"] = (float("nan"), 0.0, 0.0)
        with self.assertRaises(ValueError):
            road_route_pack.build_route_pack(network)

        network = self.golden_network()
        network["edges"]["w1:0:osm:1:osm:2"]["direction"] = 2
        with self.assertRaises(ValueError):
            road_route_pack.build_route_pack(network)


if __name__ == "__main__":
    unittest.main()
