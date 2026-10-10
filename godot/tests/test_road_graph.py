import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from road_graph import (build_network, split_segment, ribbon_tiles, polygon_area,
                        ribbon_cross_sections, joined_ribbon_tiles, road_dimensions, clip_polygon)
from build_jamaica_roads import ROAD_WIDTHS, ROAD_CLASSES, road_flags
from pyproj import Transformer

class Identity:
    def transform(self, x, y):
        return x, -y

def way(identifier, points, refs, **tags):
    return {"id": identifier, "properties": {"highway": "primary", **tags},
            "geometry": {"type": "LineString", "coordinates": points},
            "osm_node_ids": refs}

def compile_features(features, sampler=None):
    return build_network(features, Identity(), (0, 0), 10, ROAD_WIDTHS,
                         ROAD_CLASSES, road_flags, {}, sampler)

class RoadGraphTests(unittest.TestCase):
    def test_exact_seam_samples_and_length(self):
        a, b = (3, 12, 4), (33, 42, 4)
        pieces = list(split_segment(a, b, 10))
        self.assertEqual([p[0] for p in pieces], [(0, 0), (1, 0), (2, 0), (3, 0)])
        for left, right in zip(pieces, pieces[1:]):
            self.assertEqual(left[2], right[1])
        self.assertAlmostEqual(sum(math.dist(p, q) for _, p, q in pieces), math.dist(a, b))

    def test_negative_grid_and_corner(self):
        pieces = list(split_segment((-15, 0, -15), (15, 30, 15), 10))
        self.assertEqual([p[0] for p in pieces], [(-2, -2), (-1, -1), (0, 0), (1, 1)])
        self.assertEqual(pieces[1][2], (0, 15, 0))

    def test_boundary_road_has_one_centerline_owner(self):
        pieces = list(split_segment((10, 0, 1), (10, 0, 9), 10))
        self.assertEqual(len(pieces), 1)
        self.assertEqual(pieces[0][0], (1, 0))

    def test_width_clipping_has_no_overlapping_tile_area(self):
        pieces = list(ribbon_tiles((3, 0, 9), (27, 4, 13), 8, 10))
        expected = math.hypot(24, 4) * 8
        self.assertAlmostEqual(sum(polygon_area(poly) for _, poly in pieces), expected, places=4)
        for (tx, tz), polygon in pieces:
            for x, y, z in polygon:
                self.assertLessEqual(tx * 10 - 1e-6, x)
                self.assertLessEqual(x, (tx + 1) * 10 + 1e-6)
                self.assertLessEqual(tz * 10 - 1e-6, z)
                self.assertLessEqual(z, (tz + 1) * 10 + 1e-6)

    def test_bridge_crossing_without_shared_osm_node_stays_disconnected(self):
        result = compile_features([way("w1", [[-5, 0], [5, 0]], [1, 2]),
                                   way("w2", [[0, -5], [0, 5]], [3, 4], bridge="yes", layer="1")])
        self.assertEqual(len(result["nodes"]), 4)
        self.assertEqual(len(result["edges"]), 2)
        self.assertTrue(next(e for e in result["edges"].values() if e["source_way"] == "w2")["bridge"])

    def test_shared_osm_junction_splits_paths(self):
        result = compile_features([way("w1", [[0, 0], [10, 0], [20, 0]], [1, 2, 3]),
                                   way("w2", [[10, -10], [10, 0]], [4, 2])])
        self.assertEqual(len(result["edges"]), 3)
        self.assertEqual(len(result["nodes"]["osm:2"]["edges"]), 3)

    def test_direction_width_speed_and_surface_are_preserved(self):
        result = compile_features([way("w1", [[0, 0], [20, 0]], [1, 2],
                                       oneway="-1", width="7.5 m", maxspeed="40 mph", surface="gravel")])
        edge = next(iter(result["edges"].values()))
        self.assertEqual(edge["direction"], -1)
        self.assertEqual(edge["width_m"], 7.5)
        self.assertAlmostEqual(edge["speed_limit_mps"], 17.8816)
        self.assertTrue(edge["flags"] & 8)

    def test_carriageway_width_uses_source_lanes_before_class_default(self):
        self.assertEqual(road_dimensions({"highway": "motorway", "lanes": "2", "oneway": "yes"}, 14),
                         (8.4, 2, "osm:lanes (lane width inferred)"))
        self.assertEqual(road_dimensions({"highway": "primary", "lanes": "1", "width": "5.2 m"}, 7.2),
                         (5.2, 1, "osm:width"))
        self.assertAlmostEqual(road_dimensions({"highway": "service", "width": "12 ft"}, 3.5)[0], 3.6576)
        self.assertEqual(road_dimensions({"highway": "primary", "oneway": "yes"}, 7.2)[0], 4.2)
        self.assertLess(ROAD_WIDTHS["trunk"], 9.0)

    def test_adjacent_curve_ribbons_share_exact_join_with_bounded_miter(self):
        sections, station = ribbon_cross_sections([(100, 2, 100), (120, 3, 100), (120, 4, 120)], 6)
        first = list(joined_ribbon_tiles(sections, 0, 1000))[0][1]
        second = list(joined_ribbon_tiles(sections, 1, 1000))[0][1]
        self.assertEqual(set(first[-2:]), set(second[:2]))
        self.assertEqual(station, [0.0, 20.0, 40.0])
        self.assertAlmostEqual(polygon_area(first) + polygon_area(second), 240.0)
        # A near-reversing source bend may narrow, but cannot create a huge
        # triangular spike extending many road widths from the source path.
        tight, _ = ribbon_cross_sections([(0, 0, 0), (20, 0, 0), (0.1, 0, 0.5)], 6)
        self.assertLessEqual(math.hypot(tight[1][0][0] - 20, tight[1][0][2]), 4.8 + 1e-6)

    def test_closed_way_first_and_last_join_match(self):
        sections, _ = ribbon_cross_sections([(0, 0, 0), (20, 0, 0), (20, 0, 20), (0, 0, 0)], 5)
        self.assertEqual(sections[0][0][:3], sections[-1][0][:3])
        self.assertEqual(sections[0][1][:3], sections[-1][1][:3])

    def test_uv_station_and_width_attributes_are_continuous_at_tile_seams(self):
        result = compile_features([way("w1", [[0, 4], [30, 4], [40, 14]], [1, 2, 3])])
        seen = {}
        for records in result["tiles"].values():
            for record in records:
                self.assertEqual(len(record[11]), len(record[12]))
                for position, uv in zip(record[11], record[12]):
                    key = tuple(position)
                    if key in seen:
                        self.assertEqual(seen[key], uv)
                    seen[key] = uv
        self.assertEqual(next(iter(result["edges"].values()))["width_source"], "class estimate")

    def test_graph_junction_does_not_reset_uv_or_visible_join(self):
        result = compile_features([way("w1", [[0, 0], [20, 0], [20, 20]], [1, 2, 3]),
                                   way("w2", [[20, 0], [40, 0]], [2, 4])])
        way_records = [record for records in result["tiles"].values() for record in records if record[7].startswith("w1:")]
        ending = set()
        starting = set()
        for record in way_records:
            destination = ending if record[7].endswith("osm:2") else starting
            destination.update((tuple(p), tuple(uv)) for p, uv in zip(record[11], record[12]) if uv[0] == 20)
        self.assertTrue(ending)
        self.assertEqual(ending, starting)

    def test_order_does_not_change_identity_or_geometry(self):
        features = [way("w1", [[0, 0], [20, 0]], [1, 2]),
                    way("w2", [[20, 0], [20, 20]], [2, 3])]
        self.assertEqual(compile_features(features), compile_features(features[::-1]))

    def test_curve_edit_does_not_replace_logical_edge_identity(self):
        first = compile_features([way("w1", [[0, 0], [5, 2], [20, 0]], [1, 5, 2])])
        second = compile_features([way("w1", [[0, 0], [5, 3], [9, 4], [20, 0]], [1, 5, 6, 2])])
        self.assertEqual(set(first["edges"]), set(second["edges"]))

    def test_elevation_is_shared_across_clipped_tiles(self):
        result = compile_features([way("w1", [[0, 9], [30, 9]], [1, 2])], lambda x, z: x * 2)
        at_seam = []
        for segments in result["tiles"].values():
            for segment in segments:
                at_seam.extend(p[1] for p in segment[11] if p[0] == 10)
        self.assertGreaterEqual(len(at_seam), 4)
        self.assertTrue(all(y == 20 for y in at_seam))

    def test_crs_round_trip_real_jamaica(self):
        fwd = Transformer.from_crs(4326, 3448, always_xy=True)
        inv = Transformer.from_crs(3448, 4326, always_xy=True)
        for lon, lat in [(-76.7936, 17.9714), (-78.1736, 18.451), (-76.4509, 18.1762)]:
            e, n = fwd.transform(lon, lat)
            self.assertTrue(math.isfinite(e) and math.isfinite(n))
            recovered = inv.transform(e, n)
            self.assertAlmostEqual(recovered[0], lon, places=8)
            self.assertAlmostEqual(recovered[1], lat, places=8)

    def test_invalid_tile_size(self):
        with self.assertRaises(ValueError):
            list(split_segment((0, 0, 0), (1, 0, 1), 0))

if __name__ == "__main__":
    unittest.main()
