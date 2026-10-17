import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_road_earthworks import classify_earthwork, parse_width


class RoadEarthworkTests(unittest.TestCase):
    def test_source_cutting_beats_dem_candidate(self):
        kind, resolved, reason = classify_earthwork(
            {"cutting": "yes"}, -8.0, -7.0
        )
        self.assertEqual(kind, "source_cutting")
        self.assertTrue(resolved)
        self.assertIn("cutting", reason)

    def test_source_embankment_is_preserved(self):
        kind, resolved, _ = classify_earthwork(
            {"embankment": "yes"}, 8.0, 9.0
        )
        self.assertEqual(kind, "source_embankment")
        self.assertTrue(resolved)

    def test_source_ford_is_not_recast_as_cut_or_fill(self):
        kind, resolved, _ = classify_earthwork(
            {"ford": "yes"}, 6.0, 6.0
        )
        self.assertEqual(kind, "source_ford")
        self.assertTrue(resolved)

    def test_bridge_is_deferred_before_dem_earthwork(self):
        kind, resolved, _ = classify_earthwork(
            {"bridge": "yes"}, 12.0, 12.0
        )
        self.assertEqual(kind, "bridge_deferred")
        self.assertTrue(resolved)

    def test_tunnel_or_covered_road_is_deferred(self):
        for tags in ({"tunnel": "yes"}, {"covered": "yes"}):
            kind, resolved, _ = classify_earthwork(tags, 12.0, 12.0)
            self.assertEqual(kind, "tunnel_or_covered_deferred")
            self.assertTrue(resolved)

    def test_dem_cut_candidate_is_review_only(self):
        kind, resolved, _ = classify_earthwork({}, 2.1, 4.5)
        self.assertEqual(kind, "dem_cut_candidate")
        self.assertFalse(resolved)

    def test_dem_fill_candidate_is_review_only(self):
        kind, resolved, _ = classify_earthwork({}, -2.1, -5.0)
        self.assertEqual(kind, "dem_fill_candidate")
        self.assertFalse(resolved)

    def test_dem_sidehill_candidate_requires_opposing_relief(self):
        kind, resolved, _ = classify_earthwork({}, 2.0, -2.0)
        self.assertEqual(kind, "dem_sidehill_candidate")
        self.assertFalse(resolved)

    def test_low_relief_stays_unclassified(self):
        kind, resolved, _ = classify_earthwork({}, 0.9, -0.7)
        self.assertEqual(kind, "none")
        self.assertFalse(resolved)

    def test_width_parser_preserves_source_and_bounds(self):
        self.assertEqual(parse_width("7.4 m", "primary"), (7.4, "source"))
        self.assertEqual(parse_width("999", "primary"), (30.0, "source"))
        width, source = parse_width("unknown", "service")
        self.assertEqual(width, 3.5)
        self.assertEqual(source, "class_fallback")


if __name__ == "__main__":
    unittest.main()
