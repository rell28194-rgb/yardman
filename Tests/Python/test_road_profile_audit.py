from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from audit_road_profiles import audit_road_profiles


class RoadProfileAuditTests(unittest.TestCase):
    def test_reports_class_and_exact_outliers_without_rewriting_geometry(self):
        with tempfile.TemporaryDirectory() as temporary:
            roads = Path(temporary)
            graph = roads / "graph"
            graph.mkdir(parents=True)
            original = {
                "local": {
                    "id": "local",
                    "source_way": "w100",
                    "class": "secondary",
                    "flags": 0,
                    "path": [
                        [0.0, 10.0, 0.0],
                        [10.0, 12.0, 0.0],
                        [20.0, 9.0, 0.0],
                    ],
                },
                "bridge": {
                    "id": "bridge",
                    "source_way": "w200",
                    "class": "primary",
                    "flags": 2,
                    "path": [
                        [0.0, 0.0, 0.0],
                        [1.0, 50.0, 0.0],
                    ],
                },
            }
            (graph / "edges_00.json").write_text(json.dumps(original), encoding="utf-8")

            report = audit_road_profiles(roads, top_n=5)

            self.assertEqual(report["stats"]["edges"], 2)
            self.assertEqual(report["stats"]["structural_edges_skipped"], 1)
            self.assertEqual(report["stats"]["grade_segments"], 2)
            self.assertEqual(report["stats"]["grade_break_vertices"], 1)
            self.assertAlmostEqual(report["stats"]["grade_max_pct"], 30.0)
            self.assertEqual(report["stats"]["grade_over_20pct_segments"], 1)
            self.assertEqual(report["by_highway_class"]["secondary"]["segments"], 2)
            self.assertNotIn("primary", report["by_highway_class"])
            worst = report["top_grade_segments"][0]
            self.assertEqual(worst["source_way"], "w100")
            self.assertEqual(worst["segment_index"], 1)
            self.assertAlmostEqual(worst["signed_grade_pct"], -30.0)
            self.assertTrue(worst["touches_graph_endpoint"])
            self.assertEqual(json.loads((graph / "edges_00.json").read_text()), original)

    def test_requires_real_edge_shards_and_positive_top_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            roads = Path(temporary)
            with self.assertRaises(ValueError):
                audit_road_profiles(roads)
            (roads / "graph").mkdir()
            (roads / "graph" / "edges_00.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                audit_road_profiles(roads, top_n=0)


if __name__ == "__main__":
    unittest.main()
