#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

from shapely.geometry import LineString, Polygon
from shapely.strtree import STRtree

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from resolve_building_road_conflicts import (MIN_RETAINED_AREA_RATIO,
                                              road_conflicts,
                                              resolve_polygon_conflict)


def road(x0, z0, x1, z1, width, surface):
    return {
        "surface": surface,
        "centerline": LineString([(x0, z0), (x1, z1)]),
        "width_m": width,
        "key": ("fixture", 0),
    }


class BuildingRoadClearanceTests(unittest.TestCase):
    def test_shallow_roadside_contact_is_preserved(self):
        building = Polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        candidate = road(11.8, -5, 11.8, 15, 4.0,
                         Polygon([(9.8, -5), (13.8, -5), (13.8, 15), (9.8, 15)]))
        candidates = [candidate]
        tree = STRtree([candidate["surface"]])
        self.assertEqual(road_conflicts(building, candidates, tree), [])

    def test_material_edge_intrusion_is_clipped(self):
        building = Polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        candidate = road(10.5, -5, 10.5, 15, 4.0,
                         Polygon([(8.5, -5), (12.5, -5), (12.5, 15), (8.5, 15)]))
        candidates = [candidate]
        tree = STRtree([candidate["surface"]])
        conflicts = road_conflicts(building, candidates, tree)
        self.assertEqual(len(conflicts), 1)
        resolved, changed, unresolved, removed = resolve_polygon_conflict(building, conflicts)
        self.assertTrue(changed)
        self.assertFalse(unresolved)
        self.assertGreater(removed, 10.0)
        self.assertGreaterEqual(resolved.area / building.area, MIN_RETAINED_AREA_RATIO)
        self.assertLessEqual(resolved.bounds[2], 8.25 + 1e-6)

    def test_centerline_through_building_is_reported_not_invented(self):
        building = Polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        candidate = road(5, -5, 5, 15, 4.0,
                         Polygon([(3, -5), (7, -5), (7, 15), (3, 15)]))
        candidates = [candidate]
        tree = STRtree([candidate["surface"]])
        conflicts = road_conflicts(building, candidates, tree)
        self.assertEqual(len(conflicts), 1)
        resolved, changed, unresolved, removed = resolve_polygon_conflict(building, conflicts)
        self.assertFalse(changed)
        self.assertTrue(unresolved)
        self.assertEqual(removed, 0.0)
        self.assertTrue(resolved.equals(building))


if __name__ == "__main__":
    unittest.main()
