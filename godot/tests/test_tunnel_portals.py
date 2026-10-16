import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_tunnel_portals import compile_portals


class TunnelPortalTests(unittest.TestCase):
    def _dataset(self, root: Path):
        (root / "graph").mkdir(parents=True)
        # Two graph edges are one source tunnel way. osm:2 is an internal split,
        # so only osm:1 and osm:3 are real portals.
        edges = {
            "e1": {"id": "e1", "source_way": "w10", "from": "osm:1", "to": "osm:2",
                   "path": [[5.0, 20.0, 5.0], [30.0, 18.0, 5.0]], "width_m": 7.0,
                   "tunnel": True, "layer": "-1"},
            "e2": {"id": "e2", "source_way": "w10", "from": "osm:2", "to": "osm:3",
                   "path": [[30.0, 18.0, 5.0], [70.0, 16.0, 5.0]], "width_m": 7.0,
                   "tunnel": True, "layer": "-1"},
            "passage": {"id": "passage", "source_way": "w20", "from": "osm:4", "to": "osm:5",
                        "path": [[5.0, 3.0, 80.0], [15.0, 3.0, 80.0]], "width_m": 5.0,
                        "tunnel": True, "layer": "0"},
        }
        (root / "graph" / "edges_00.json").write_text(json.dumps(edges))
        (root / "manifest.json").write_text(json.dumps({"tile_size": 64.0}))

    def test_internal_graph_split_does_not_create_fake_portal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._dataset(root)
            result = compile_portals(root)
            self.assertEqual(result["profiled_tunnel_source_ways"], 1)
            self.assertEqual(result["portals"], 2)
            portals = []
            for tile in result["tiles"]:
                payload = json.loads((root / "tunnel_portals" / tile["file"]).read_text())
                portals.extend(payload["portals"])
            self.assertEqual({p["node_id"] for p in portals}, {"osm:1", "osm:3"})
            self.assertNotIn("osm:2", {p["node_id"] for p in portals})
            self.assertEqual(result["anomalies"], [])

    def test_layer_zero_passage_is_not_terrain_portal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._dataset(root)
            result = compile_portals(root)
            self.assertNotIn("w20", result["source_way_counts"])

    def test_portal_direction_points_into_tunnel(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._dataset(root)
            result = compile_portals(root)
            portals = []
            for tile in result["tiles"]:
                portals.extend(json.loads((root / "tunnel_portals" / tile["file"]).read_text())["portals"])
            start = next(p for p in portals if p["node_id"] == "osm:1")
            end = next(p for p in portals if p["node_id"] == "osm:3")
            self.assertEqual(start["position"], [5.0, 20.0, 5.0])
            self.assertEqual(start["toward"], [30.0, 18.0, 5.0])
            self.assertEqual(end["position"], [70.0, 16.0, 5.0])
            self.assertEqual(end["toward"], [30.0, 18.0, 5.0])

    def test_national_manifest_names_every_portal_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._dataset(root)
            result = compile_portals(root)
            registry = json.loads((root / "manifest.json").read_text())["tunnel_portals"]
            self.assertEqual(registry["portals"], result["portals"])
            self.assertEqual(registry["profiled_tunnel_source_ways"], 1)
            self.assertTrue((root / registry["manifest_file"]).is_file())
            self.assertEqual(sum(tile["portals"] for tile in registry["tiles"]), 2)
            self.assertTrue(all((root / tile["file"]).is_file() for tile in registry["tiles"]))


if __name__ == "__main__":
    unittest.main()
