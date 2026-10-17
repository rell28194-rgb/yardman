import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_places import (
    PLACE_KINDS,
    PARISH_CAPITALS,
    _dedupe,
    _nearest_parish,
    canonical_parish_name,
    classify_place,
    geometry_contains,
    is_capital,
    parish_from_boundaries,
    point_in_ring,
)


class PlaceCompilerTests(unittest.TestCase):
    def test_supported_named_place_types(self):
        for kind in PLACE_KINDS:
            self.assertEqual(classify_place({"place": kind, "name": "X"}), kind)
        self.assertEqual(classify_place({"place": "island", "name": "X"}), "")

    def test_named_pedestrian_area_is_square(self):
        self.assertEqual(classify_place({"highway": "pedestrian", "area": "yes", "name": "Sam Sharpe Square"}), "square")
        self.assertEqual(classify_place({"highway": "pedestrian", "name": "Unnamed area"}), "")

    def test_capital_tags_are_explicit(self):
        self.assertTrue(is_capital({"capital": "yes"}))
        self.assertTrue(is_capital({"capital": "4"}))
        self.assertFalse(is_capital({}))
        self.assertFalse(is_capital({"capital": "no"}))

    def test_parish_capital_fallback_covers_all_parishes(self):
        self.assertEqual(len(PARISH_CAPITALS), 14)
        self.assertEqual(PARISH_CAPITALS["St. James"][0], "Montego Bay")
        self.assertEqual(PARISH_CAPITALS["Manchester"][0], "Mandeville")
        self.assertEqual(PARISH_CAPITALS["Kingston"][0], "Kingston")

    def test_parish_name_aliases_normalize_to_canonical_names(self):
        self.assertEqual(canonical_parish_name("Saint Andrew Parish"), "St. Andrew")
        self.assertEqual(canonical_parish_name("St. Catherine"), "St. Catherine")
        self.assertEqual(canonical_parish_name({"official_name": "Saint Elizabeth Parish"}), "St. Elizabeth")
        self.assertEqual(canonical_parish_name({"name": "Kingston Parish"}), "Kingston")
        self.assertEqual(canonical_parish_name("Jamaica"), "")

    def test_nearest_parish_remains_only_a_metric_fallback(self):
        anchors = {"A": (0.0, 0.0), "B": (1000.0, 0.0)}
        self.assertEqual(_nearest_parish(50.0, 20.0, anchors), "A")
        self.assertEqual(_nearest_parish(950.0, -10.0, anchors), "B")

    def test_polygon_containment_counts_edges_and_excludes_holes(self):
        outer = [[-78.0, 17.0], [-76.0, 17.0], [-76.0, 19.0], [-78.0, 19.0], [-78.0, 17.0]]
        hole = [[-77.2, 17.8], [-76.8, 17.8], [-76.8, 18.2], [-77.2, 18.2], [-77.2, 17.8]]
        geometry = {"type": "Polygon", "coordinates": [outer, hole]}
        self.assertTrue(point_in_ring(-77.5, 18.0, outer))
        self.assertTrue(point_in_ring(-78.0, 18.0, outer))
        self.assertTrue(geometry_contains(geometry, -77.5, 18.0))
        self.assertFalse(geometry_contains(geometry, -77.0, 18.0))
        self.assertFalse(geometry_contains(geometry, -75.9, 18.0))

    def test_boundary_assignment_rejects_overlap_instead_of_guessing(self):
        west = {"type": "Polygon", "coordinates": [[[-78.0, 17.0], [-77.0, 17.0], [-77.0, 19.0], [-78.0, 19.0], [-78.0, 17.0]]]}
        east = {"type": "Polygon", "coordinates": [[[-77.0, 17.0], [-76.0, 17.0], [-76.0, 19.0], [-77.0, 19.0], [-77.0, 17.0]]]}
        boundaries = {"West": [west], "East": [east]}
        self.assertEqual(parish_from_boundaries(-77.5, 18.0, boundaries), "West")
        self.assertEqual(parish_from_boundaries(-76.5, 18.0, boundaries), "East")
        self.assertEqual(parish_from_boundaries(-77.0, 18.0, boundaries), "")

    def test_dedupe_preserves_square_and_settlement_layers(self):
        records = [
            {"name": "Example", "kind": "town", "capital": False, "source": "node/1"},
            {"name": "Example", "kind": "town", "capital": True, "source": "node/2"},
            {"name": "Example", "kind": "square", "capital": False, "source": "way/3"},
        ]
        result = _dedupe(records)
        self.assertEqual(len(result), 2)
        town = next(r for r in result if r["kind"] == "town")
        self.assertTrue(town["capital"])

    def test_dedupe_does_not_delete_same_named_places_across_jamaica(self):
        records = [
            {"name": "Springfield", "kind": "village", "capital": False, "source": "node/1", "x": 100.0, "z": 100.0},
            {"name": "Springfield", "kind": "village", "capital": False, "source": "node/2", "x": 120.0, "z": 115.0},
            {"name": "Springfield", "kind": "village", "capital": False, "source": "node/3", "x": 12000.0, "z": 8000.0},
        ]
        result = _dedupe(records)
        self.assertEqual(len(result), 2)


if __name__ == "__main__":
    unittest.main()
