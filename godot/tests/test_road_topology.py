import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from validate_road_topology import validate


def node(identifier, x, z, edges):
    return {"id": identifier, "position": [x, 0.0, z], "edges": edges}


def edge(identifier, a, b, path, direction=0, layer="0", bridge=False, tunnel=False,
         road_class="primary", source_way=None):
    length = sum(((q[0] - p[0]) ** 2 + (q[2] - p[2]) ** 2) ** 0.5 for p, q in zip(path, path[1:]))
    return {"id": identifier, "from": a, "to": b, "path": path, "direction": direction,
            "layer": layer, "bridge": bridge, "tunnel": tunnel, "class": road_class,
            "source_way": source_way or identifier, "length_m": length}


def write_graph(root: Path, nodes: dict, edges: dict, anchors: dict):
    graph = root / "graph"
    graph.mkdir(parents=True)
    (graph / "nodes_00.json").write_text(json.dumps(nodes))
    (graph / "edges_00.json").write_text(json.dumps(edges))
    manifest = {"graph": {"nodes": len(nodes), "edges": len(edges)}, "parish_anchors": anchors}
    (root / "manifest.json").write_text(json.dumps(manifest))


class RoadTopologyTests(unittest.TestCase):
    def test_connected_anchor_network_passes_and_reports_single_component(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nodes = {
                "a": node("a", 0, 0, ["e1"]),
                "b": node("b", 10, 0, ["e1", "e2"]),
                "c": node("c", 20, 0, ["e2"]),
            }
            edges = {
                "e1": edge("e1", "a", "b", [[0, 0, 0], [10, 0, 0]]),
                "e2": edge("e2", "b", "c", [[10, 0, 0], [20, 0, 0]]),
            }
            anchors = {
                "Kingston": {"x": 2, "z": 0, "road_edge_id": "e1"},
                "Portland": {"x": 18, "z": 0, "road_edge_id": "e2"},
            }
            write_graph(root, nodes, edges, anchors)
            report = validate(root, require_anchor_component=True)
            self.assertEqual(report["components"]["count"], 1)
            self.assertEqual(report["parish_anchors"]["component_count"], 1)
            self.assertEqual(report["parish_anchors"]["directed_from_kingston"]["unreachable"], [])

    def test_disconnected_parish_anchor_fails_strict_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nodes = {
                "a": node("a", 0, 0, ["e1"]), "b": node("b", 10, 0, ["e1"]),
                "c": node("c", 100, 0, ["e2"]), "d": node("d", 110, 0, ["e2"]),
            }
            edges = {
                "e1": edge("e1", "a", "b", [[0, 0, 0], [10, 0, 0]]),
                "e2": edge("e2", "c", "d", [[100, 0, 0], [110, 0, 0]]),
            }
            anchors = {
                "Kingston": {"x": 2, "z": 0, "road_edge_id": "e1"},
                "Portland": {"x": 102, "z": 0, "road_edge_id": "e2"},
            }
            write_graph(root, nodes, edges, anchors)
            with self.assertRaisesRegex(ValueError, "disconnected road components"):
                validate(root, require_anchor_component=True)

    def test_one_way_direction_is_used_for_anchor_reachability(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nodes = {
                "a": node("a", 0, 0, ["e1"]),
                "b": node("b", 10, 0, ["e1", "e2"]),
                "c": node("c", 20, 0, ["e2"]),
            }
            # e2 points from c back to b. Kingston can depart e1 at b but cannot drive b -> c.
            edges = {
                "e1": edge("e1", "a", "b", [[0, 0, 0], [10, 0, 0]], direction=1),
                "e2": edge("e2", "c", "b", [[20, 0, 0], [10, 0, 0]], direction=1),
            }
            anchors = {
                "Kingston": {"x": 5, "z": 0, "road_edge_id": "e1"},
                "Portland": {"x": 15, "z": 0, "road_edge_id": "e2"},
            }
            write_graph(root, nodes, edges, anchors)
            report = validate(root, require_anchor_component=True)
            self.assertIn("Portland", report["parish_anchors"]["directed_from_kingston"]["unreachable"])

    def test_same_grade_near_miss_is_reported_without_modifying_graph(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nodes = {
                "a": node("a", 0, 0, ["e1"]), "b": node("b", 10, 0, ["e1"]),
                "c": node("c", 11.5, 0, ["e2"]), "d": node("d", 20, 0, ["e2"]),
            }
            edges = {
                "e1": edge("e1", "a", "b", [[0, 0, 0], [10, 0, 0]]),
                "e2": edge("e2", "c", "d", [[11.5, 0, 0], [20, 0, 0]]),
            }
            anchors = {"Kingston": {"x": 2, "z": 0, "road_edge_id": "e1"}}
            write_graph(root, nodes, edges, anchors)
            report = validate(root, near_miss_metres=2.5)
            pair = next(x for x in report["suspect_near_misses"] if {x["a"], x["b"]} == {"b", "c"})
            self.assertAlmostEqual(pair["distance_m"], 1.5)
            self.assertEqual(report["components"]["count"], 2)

    def test_grade_separated_near_miss_is_not_flagged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nodes = {
                "a": node("a", 0, 0, ["e1"]), "b": node("b", 10, 0, ["e1"]),
                "c": node("c", 11, 0, ["e2"]), "d": node("d", 20, 0, ["e2"]),
            }
            edges = {
                "e1": edge("e1", "a", "b", [[0, 0, 0], [10, 0, 0]], layer="0"),
                "e2": edge("e2", "c", "d", [[11, 0, 0], [20, 0, 0]], layer="1", bridge=True),
            }
            anchors = {"Kingston": {"x": 2, "z": 0, "road_edge_id": "e1"}}
            write_graph(root, nodes, edges, anchors)
            report = validate(root, near_miss_metres=2.5)
            self.assertFalse(any({x["a"], x["b"]} == {"b", "c"} for x in report["suspect_near_misses"]))


if __name__ == "__main__":
    unittest.main()
