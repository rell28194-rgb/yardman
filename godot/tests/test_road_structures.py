import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_road_structures import compile_structures, _clip_axis_to_tile


def write_dataset(root: Path):
    (root / "graph").mkdir(parents=True)
    bridge_id = "bridge:0:osm:1:osm:2"
    tunnel_id = "tunnel:0:osm:3:osm:4"
    passage_id = "passage:0:osm:5:osm:6"
    edges = {
        bridge_id: {
            "id": bridge_id, "source_way": "bridge", "from": "osm:1", "to": "osm:2",
            "path": [[0.0, 10.0, 0.0], [10.0, -5.0, 0.0], [20.0, 14.0, 0.0]],
            "length_m": 20.0, "class": "primary", "bridge": True, "tunnel": False,
            "layer": "1", "direction": 0,
        },
        tunnel_id: {
            "id": tunnel_id, "source_way": "tunnel", "from": "osm:3", "to": "osm:4",
            "path": [[0.0, 20.0, 50.0], [10.0, 48.0, 50.0], [20.0, 22.0, 50.0]],
            "length_m": 20.0, "class": "primary", "bridge": False, "tunnel": True,
            "layer": "-1", "direction": 0,
        },
        passage_id: {
            "id": passage_id, "source_way": "passage", "from": "osm:5", "to": "osm:6",
            "path": [[0.0, 7.0, 80.0], [12.0, 9.0, 80.0]],
            "length_m": 12.0, "class": "residential", "bridge": False, "tunnel": True,
            "layer": "0", "direction": 0,
        },
    }
    (root / "graph" / "edges_00.json").write_text(json.dumps(edges))
    nodes = {
        "osm:1": {"id": "osm:1", "position": [0.0, 10.0, 0.0], "edges": [bridge_id]},
        "osm:2": {"id": "osm:2", "position": [20.0, 14.0, 0.0], "edges": [bridge_id]},
        "osm:3": {"id": "osm:3", "position": [0.0, 20.0, 50.0], "edges": [tunnel_id]},
        "osm:4": {"id": "osm:4", "position": [20.0, 22.0, 50.0], "edges": [tunnel_id]},
        "osm:5": {"id": "osm:5", "position": [0.0, 7.0, 80.0], "edges": [passage_id]},
        "osm:6": {"id": "osm:6", "position": [12.0, 9.0, 80.0], "edges": [passage_id]},
    }
    (root / "graph" / "nodes_00.json").write_text(json.dumps(nodes))

    bridge_0 = [0.0, 0.0, 10.0, 0.0, 7.2, 4, 2, bridge_id, 0, 10.0, -5.0,
                [[0.0, 10.0, -3.6], [10.0, -5.0, -3.6], [10.0, -5.0, 3.6], [0.0, 10.0, 3.6]],
                [[0.0, -3.6], [10.0, -3.6], [10.0, 3.6], [0.0, 3.6]], 1, 2, 13.9, 0.0, 20.0]
    bridge_1 = [10.0, 0.0, 20.0, 0.0, 7.2, 4, 2, bridge_id, 1, -5.0, 14.0,
                [[10.0, -5.0, -3.6], [20.0, 14.0, -3.6], [20.0, 14.0, 3.6], [10.0, -5.0, 3.6]],
                [[10.0, -3.6], [20.0, -3.6], [20.0, 3.6], [10.0, 3.6]], 1, 2, 13.9, 0.0, 20.0]
    tunnel_0 = [0.0, 50.0, 10.0, 50.0, 7.2, 4, 4, tunnel_id, 0, 20.0, 48.0,
                [[0.0, 20.0, 46.4], [10.0, 48.0, 46.4], [10.0, 48.0, 53.6], [0.0, 20.0, 53.6]],
                [[0.0, -3.6], [10.0, -3.6], [10.0, 3.6], [0.0, 3.6]], 1, 2, 13.9, 0.0, 20.0]
    tunnel_1 = [10.0, 50.0, 20.0, 50.0, 7.2, 4, 4, tunnel_id, 1, 48.0, 22.0,
                [[10.0, 48.0, 46.4], [20.0, 22.0, 46.4], [20.0, 22.0, 53.6], [10.0, 48.0, 53.6]],
                [[10.0, -3.6], [20.0, -3.6], [20.0, 3.6], [10.0, 3.6]], 1, 2, 13.9, 0.0, 20.0]
    passage = [0.0, 80.0, 12.0, 80.0, 5.5, 6, 4, passage_id, 0, 7.0, 9.0,
               [[0.0, 7.0, 77.25], [12.0, 9.0, 77.25], [12.0, 9.0, 82.75], [0.0, 7.0, 82.75]],
               [[0.0, -2.75], [12.0, -2.75], [12.0, 2.75], [0.0, 2.75]], 0, 2, None, 0.0, 12.0]
    tile = {"tile": [0, 0], "segments": [bridge_0, bridge_1, tunnel_0, tunnel_1, passage]}
    (root / "tile_0_0.json").write_text(json.dumps(tile))
    manifest = {
        "format": 3,
        "tile_size": 128.0,
        "graph": {"nodes": 6, "edges": 3},
        "tiles": [{"x": 0, "z": 0, "file": "tile_0_0.json", "segments": 5}],
    }
    (root / "manifest.json").write_text(json.dumps(manifest))
    return bridge_id, tunnel_id, passage_id


class RoadStructureTests(unittest.TestCase):
    def test_cross_tile_tunnel_axis_keeps_exact_seam_elevation(self):
        a, b = [4000.0, 30.0, 100.0], [4200.0, 50.0, 100.0]
        left = _clip_axis_to_tile(a, b, 0, 0, 4096.0)
        right = _clip_axis_to_tile(a, b, 1, 0, 4096.0)
        self.assertEqual(left[1], right[0])
        self.assertEqual(left[1], [4096.0, 39.6, 100.0])
        self.assertLess(left[0][0], left[1][0])
        self.assertLess(right[0][0], right[1][0])
        self.assertNotEqual(left, right)

    def test_ribbon_overlap_does_not_duplicate_outside_centerline(self):
        self.assertIsNone(_clip_axis_to_tile(
            [10.0, 4.0, 4098.0], [60.0, 8.0, 4098.0], 0, 0, 4096.0))

    def test_axis_exactly_on_tile_boundary_has_one_owner(self):
        a, b = [10.0, 4.0, 4096.0], [60.0, 8.0, 4096.0]
        self.assertIsNone(_clip_axis_to_tile(a, b, 0, 0, 4096.0))
        self.assertEqual(_clip_axis_to_tile(a, b, 0, 1, 4096.0), (a, b))

    def test_negative_tile_and_diagonal_axis_clipping(self):
        a, b = [-10.0, 4.0, -10.0], [10.0, 8.0, 10.0]
        negative = _clip_axis_to_tile(a, b, -1, -1, 4096.0)
        positive = _clip_axis_to_tile(a, b, 0, 0, 4096.0)
        self.assertEqual(negative[1], [0.0, 6.0, 0.0])
        self.assertEqual(negative[1], positive[0])

    def test_bridge_deck_removes_interior_dem_drape_and_keeps_abutments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bridge_id, _, _ = write_dataset(root)
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
            bridge_id, _, _ = write_dataset(root)
            compile_structures(root)
            tile = json.loads((root / "tile_0_0.json").read_text())
            records = [s for s in tile["segments"] if s[7] == bridge_id]
            samples = []
            for record in records:
                for point, uv in zip(record[11], record[12]):
                    if abs(float(uv[0]) - 10.0) < 1e-9:
                        samples.append(float(point[1]))
            self.assertTrue(samples)
            self.assertTrue(all(abs(y - 12.0) < 1e-6 for y in samples))

    def test_negative_layer_tunnel_gets_portal_profile_and_compact_corridor_tile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, tunnel_id, _ = write_dataset(root)
            summary = compile_structures(root)
            edge = json.loads((root / "graph" / "edges_00.json").read_text())[tunnel_id]
            self.assertEqual(edge["path"][0][1], 20.0)
            self.assertAlmostEqual(edge["path"][1][1], 21.0)
            self.assertEqual(edge["path"][-1][1], 22.0)
            self.assertEqual(summary["tunnel"]["profiled_edges"], 1)
            self.assertGreater(summary["tunnel"]["maximum_removed_dem_drape_m"], 26.0)
            corridor = json.loads((root / "structures" / "tile_0_0.json").read_text())
            self.assertEqual(len(corridor["tunnels"]), 2)
            self.assertEqual({item["edge_id"] for item in corridor["tunnels"]}, {tunnel_id})

    def test_layer_zero_tunnel_is_deferred_without_cutting_terrain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, _, passage_id = write_dataset(root)
            before = json.loads((root / "graph" / "edges_00.json").read_text())[passage_id]["path"]
            summary = compile_structures(root)
            after = json.loads((root / "graph" / "edges_00.json").read_text())[passage_id]["path"]
            self.assertEqual(before, after)
            self.assertEqual(summary["tunnel"]["source_edges"], 2)
            self.assertEqual(summary["tunnel"]["deferred_nonnegative_layer_edges"], 1)

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
