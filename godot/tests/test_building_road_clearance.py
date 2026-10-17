#!/usr/bin/env python3
from __future__ import annotations
import sys,unittest
from pathlib import Path
from shapely.geometry import LineString,Polygon
from shapely.strtree import STRtree
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tools"))
from resolve_building_road_conflicts import (CLEARANCE_MARGIN_M,MIN_RETAINED_AREA_RATIO,VISUAL_ENVELOPE_MARGIN_M,road_conflicts,resolve_polygon_conflict,triangulate_roof)

def road(x0,z0,x1,z1,width,surface):
    return {"surface":surface,"centerline":LineString([(x0,z0),(x1,z1)]),"width_m":width,"key":("fixture",0)}

class BuildingRoadClearanceTests(unittest.TestCase):
    def test_shallow_roadside_contact_is_preserved(self):
        building=Polygon([(0,0),(10,0),(10,10),(0,10)])
        candidate=road(11.8,-5,11.8,15,4.0,Polygon([(9.8,-5),(13.8,-5),(13.8,15),(9.8,15)]))
        self.assertEqual(road_conflicts(building,[candidate],STRtree([candidate["surface"]])),[])

    def test_material_edge_intrusion_reserves_visible_roof_envelope(self):
        building=Polygon([(0,0),(10,0),(10,10),(0,10)])
        road_edge=8.5
        candidate=road(10.5,-5,10.5,15,4.0,Polygon([(road_edge,-5),(12.5,-5),(12.5,15),(road_edge,15)]))
        conflicts=road_conflicts(building,[candidate],STRtree([candidate["surface"]]))
        self.assertEqual(len(conflicts),1)
        resolved,changed,unresolved,removed=resolve_polygon_conflict(building,conflicts)
        self.assertTrue(changed);self.assertFalse(unresolved);self.assertGreater(removed,10.0)
        self.assertGreaterEqual(resolved.area/building.area,MIN_RETAINED_AREA_RATIO)
        # The corrected wall plus the runtime's known 0.16m inferred eave must
        # still end at least the original 0.25m safety margin from the road.
        visible_edge=resolved.bounds[2]+VISUAL_ENVELOPE_MARGIN_M
        self.assertLessEqual(visible_edge,road_edge-CLEARANCE_MARGIN_M+1e-6)

    def test_centerline_through_building_is_reported_not_invented(self):
        building=Polygon([(0,0),(10,0),(10,10),(0,10)])
        candidate=road(5,-5,5,15,4.0,Polygon([(3,-5),(7,-5),(7,15),(3,15)]))
        conflicts=road_conflicts(building,[candidate],STRtree([candidate["surface"]]))
        resolved,changed,unresolved,removed=resolve_polygon_conflict(building,conflicts)
        self.assertFalse(changed);self.assertTrue(unresolved);self.assertEqual(removed,0.0);self.assertTrue(resolved.equals(building))

    def test_roof_triangulation_covers_concave_clipped_footprint_with_courtyard(self):
        shell=[(0,0),(12,0),(12,3),(8,3),(8,12),(0,12)]
        hole=[(2,2),(4,2),(4,4),(2,4)]
        building=Polygon(shell,[hole])
        triangles=triangulate_roof(building)
        self.assertGreater(len(triangles),0)
        covered=sum(t.area for t in triangles)
        self.assertAlmostEqual(covered,building.area,places=5)
        for triangle in triangles:self.assertTrue(building.covers(triangle))

if __name__=="__main__":unittest.main()
