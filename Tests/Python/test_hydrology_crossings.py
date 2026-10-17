import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_hydrology_crossings import classify_crossing


class HydrologyCrossingTests(unittest.TestCase):
    def test_explicit_road_bridge_wins_for_open_waterway(self):
        kind, reason, final = classify_crossing(
            {"highway": "primary", "bridge": "yes", "layer": "1"},
            {"waterway": "river"},
            False,
        )
        self.assertEqual(kind, "road_bridge")
        self.assertTrue(final)
        self.assertIn("bridge", reason)

    def test_explicit_culvert_prevents_open_channel_cut(self):
        kind, _, final = classify_crossing(
            {"highway": "secondary"},
            {"waterway": "stream", "tunnel": "culvert", "layer": "-1"},
            True,
        )
        self.assertEqual(kind, "waterway_culvert")
        self.assertTrue(final)

    def test_covered_waterway_is_protected_as_underground(self):
        kind, _, final = classify_crossing(
            {"highway": "residential"},
            {"waterway": "drain", "covered": "yes"},
            True,
        )
        self.assertEqual(kind, "waterway_underground")
        self.assertTrue(final)

    def test_road_tunnel_is_not_recast_as_bridge(self):
        kind, _, final = classify_crossing(
            {"highway": "primary", "tunnel": "yes", "layer": "-1"},
            {"waterway": "river", "layer": "0"},
            False,
        )
        self.assertEqual(kind, "road_tunnel")
        self.assertTrue(final)

    def test_ford_requires_source_tag(self):
        kind, _, final = classify_crossing(
            {"highway": "track", "ford": "yes"},
            {"waterway": "stream"},
            True,
        )
        self.assertEqual(kind, "ford")
        self.assertTrue(final)

    def test_layer_difference_is_not_promoted_to_a_fake_bridge(self):
        kind, _, final = classify_crossing(
            {"highway": "primary", "layer": "1"},
            {"waterway": "river", "layer": "0"},
            False,
        )
        self.assertEqual(kind, "layer_grade_separation")
        self.assertFalse(final)

    def test_shared_node_without_structure_evidence_stays_unresolved(self):
        kind, _, final = classify_crossing(
            {"highway": "residential"},
            {"waterway": "stream"},
            True,
        )
        self.assertEqual(kind, "at_grade_shared_node_unresolved")
        self.assertFalse(final)

    def test_planar_crossing_without_shared_node_stays_unresolved(self):
        kind, _, final = classify_crossing(
            {"highway": "secondary"},
            {"waterway": "river"},
            False,
        )
        self.assertEqual(kind, "geometric_crossing_unresolved")
        self.assertFalse(final)


if __name__ == "__main__":
    unittest.main()
