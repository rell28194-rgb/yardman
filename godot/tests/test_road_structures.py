import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_road_structures import compile_structures


def write_dataset(root: Path):
    (root / "graph").mkdir(parents=True)
    bridge_id = "bridge:0:osm:1:osm:2"
    tunnel_id = "tunnel:0:osm:3:osm:4"
    edges = {
        bridge_id: {
            "id": bridge_id, "source_way": "bridge", "from": "osm:1", "to": "osm:2",
            "path": [[0.0, 10.0, 0.0], [10.0, -5.0, 0.0], [20.0, 14.0, 0.0]],
            "length_m": 20.0, "class": "primary", "bridge": True, "tunnel": False,
            "layer": "1", "direction": 0,
        },
        tunnel_id: {
            "id": tunnel_id, "source_way": "tunnel", "from": "osm:3", "to": "osm:4",
            "path": [[0.0, 20.0, 50.0], [10.0, 30.0, 50.0]],
            "length_m": 10.0, "class": "primary", "bridge": False, "tunnel": True,
            "layer": "-1", "direction": 0,
        },
    }
    (root / "graph" / "edges_00.json").write_text(json.dumps(edges))
    # Node partitions only need to exist for a structurally valid dataset; the
    # structure pass intentionally does not rewrite graph nodes/abutments.
    nodes = {
        "osm:1": {"id": "osm:1", "position": [0.0, 10.0, 0.0], "edges": [bridge_id]},
        "osm:2": {"id": "osm:2", "position": [20.0, 14.0, 0.0], "edges": [bridge_id]},
        "osm:3": {"id": "osm:3", "position": [0.0, 20.0, 50.0], "edges": [tunnel_id]},
        "osm:4": {"id": "osm:4", "position": [10.0, 30.0, 50.0], "edges": [tunnel_id]},
    }
    (root / "graph" / "nodes_00.json").write_text(json.dumps(nodes))
    bridge_segment = [0.0, 0.0, 20.0, 0.0, 7.2, 4, 2, bridge_id, 0, 10.0, -5.0,
                      [[0.0, 10.0, -3.6], [10.0, -5.0, -3.6], [10.0, -5.0, 3.6], [0.0, 10.0, 3.6]],
                      [[0.0, -3.6], [10.0, -3.6], [10.0, 3.6], [0.0, 3.6]], 1, 2, 13.9, 0.0, 20.0]
    bridge_segment_2 = [0.0, 0.0, 20.0, 0.0, 7.2, 4, 2, bridge_id, 1, -5.0, 14.0,
                        [[10.0, -5.0, -3.6], [20.0, 14.0, -3.6], [20.0, 14.0, 3.6], [10.0, -5.0, 3.6]],
                        [[10.0, -3.6], [20.0, -3.6], [20.0, 3.6], [10.0, 3.6]], 1, 2, 13.9, 0.0, 20.0]
    tunnel_segment = [0.0, 50.0, 10.0, 50.0, 7.2, 4, 4, tunnel_id, 0, 20.0, 30.0,
                      [[0.0, 20.0, 46.4], [10.0, 30.0, 46.4], [10.0, 30.0, 53.6], [0.0, 20.0, 53.6]],
                      [[0.0, -3.6], [10.0, -3.6], [10.0, 3.6], [0.0, 3.6]], 1, 2, 13.9, 0.0, 10.0]
    tile = {"tile": [0, 0], "segments": [bridge_segment, bridge_segment_2, tunnel_segment]}
    (root / "tile_0_0.json").write_text(json.dumps(tile))
    manifest = {
        "format": 3,
        "graph": {"nodes": 4, "edges": 2},
        "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "segments": 3}],
    }
    (root / "manifest.json").write_text(json.dumps(manifest))
    return bridge_id, tunnel_id


class RoadStructureTests(unittest.TestCase):
    def test_bridge_deck_removes_interior_dem_drape_and_keeps_abutments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bridge_id, _ = write_dataset(root)
            summary = compile_structures(root)
            edges = json.loads((root / "graph" / "edges_00.json").read_text())
            path = edges[bridge_id]["path"]
            self.assertEqual(path[0][1], 10.0)
            self.assertEqual(path[-1][1], 14.0)
            self.assertAlmostEqual(path[1][1], 12.0)
            self.assertEqual(summary["bridge"]["edges"], 1)
            self.assertGreater(summary["bridge"]["maximum_removed_dem_drape_m"], 16.0)

    def test_bridge_render_polygons_follow_same_continuous_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bridge_id, _ = write_dataset(root)
            compile_structures(root)
            tile = json.loads((root / "tile_0_0.json").read_text())
            records = [s for s in tile["segments"] if s[7] == bridge_id]
            ys_at_midpoint = [p[1] for s in records for p in s[11] if abs(float(s[12][s[11].index(p)][0]) - 10.0) < 1e-9]
            self.assertTrue(ys_at_midpoint)
            self.assertTrue(all(abs(y - 12.0) < 1e-6 for y in ys_at_midpoint))

    def test_tunnel_is_not_lowered_before_corridor_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, tunnel_id = write_dataset(root)
            before = json.loads((root / "graph" / "edges_00.json").read_text())[tunnel_id]["path"]
            summary = compile_structures(root)
            after = json.loads((root / "graph" / "edges_00.json").read_text())[tunnel_id]["path"]
            self.assertEqual(before, after)
            self.assertEqual(summary["tunnel"]["edges"], 1)
            self.assertIn("corridor", summary["tunnel"]["status"])

    def test_structure_pass_is_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_dataset(root)
            first = compile_structures(root)
            files_first = {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            second = compile_structures(root)
            files_second = {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            self.assertEqual(first, second)
            self.assertEqual(files_first, files_second)


if __name__ == "__main__":
    unittest.main()
