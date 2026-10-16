"""Footprint geometry and cell-pack tests; no national downloads needed."""
from __future__ import annotations
import gzip
import json
import math
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import shapely
from shapely.geometry import Polygon, Point

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_buildings import (building_height, conform_ring, make_record,
                             parse_height, read_cell, write_pack)


class TriangleTerrain:
    spacing = 64.0

    def __call__(self, x, z):
        # All neighbors share vertex heights, exactly like the national DEM.
        u, v = (x % 64.0) / 64.0, (z % 64.0) / 64.0
        ix, iz = math.floor(x / 64.0), math.floor(z / 64.0)
        def vertex(a, b):
            return ((a * 3 + b * 7) % 5) * 3.0
        a, b, c, d = vertex(ix, iz), vertex(ix + 1, iz), vertex(ix, iz + 1), vertex(ix + 1, iz + 1)
        if u + v <= 1:
            return a + (b - a) * u + (c - a) * v
        return d + (c - d) * (1 - u) + (b - d) * (1 - v)


class BuildingsTests(unittest.TestCase):
    def test_source_height_and_levels_precede_declared_inference(self):
        self.assertEqual(parse_height("20 ft"), 6.096)
        self.assertIsNone(parse_height("eleven"))
        self.assertIsNone(parse_height("-3"))
        self.assertEqual(building_height({"height": "12 m", "building:levels": "2"}), (12.0, 1))
        self.assertEqual(building_height({"building:levels": "2"}), (6.65, 2))
        self.assertEqual(building_height({"building": "house"}), (4.1, 3))

    def test_courtyard_roof_has_no_triangles_across_hole(self):
        polygon = Polygon([(0, 0), (30, 0), (30, 30), (0, 30)], [[(10, 10), (10, 20), (20, 20), (20, 10)]])
        cell, record, reach = make_record("r500:0", polygon, {"height": "9"}, lambda x, z: x * .1 + z * .05)
        self.assertEqual(cell, (0, 0))
        self.assertEqual(len(record[5]), 2)
        roof_area = 0.0
        for index in range(0, len(record[7]), 3):
            points = [record[6][record[7][index + v]] for v in range(3)]
            triangle = Polygon(points)
            self.assertTrue(polygon.covers(triangle))
            self.assertFalse(triangle.contains(Point(15, 15)))
            roof_area += triangle.area
        self.assertAlmostEqual(roof_area, 800.0, places=4)
        self.assertGreater(reach, 0)
        self.assertEqual(record[2], 1)
        self.assertEqual(record[4], 13.5)

    def test_wall_base_matches_full_piecewise_terrain_edge(self):
        terrain = TriangleTerrain()
        ring = conform_ring([(9, 9), (100, 79), (130, 40), (9, 9)], terrain)
        self.assertGreater(len(ring), 3)
        for before, after in zip(ring, ring[1:] + ring[:1]):
            for fraction in [0.2, 0.5, 0.8]:
                x = before[0] + (after[0] - before[0]) * fraction
                z = before[2] + (after[2] - before[2]) * fraction
                height = before[1] + (after[1] - before[1]) * fraction
                self.assertAlmostEqual(height, terrain(x, z), delta=0.00005)

    def test_cell_ownership_keeps_seam_building_whole_once(self):
        polygon = Polygon([(-4, -4), (8, -4), (8, 8), (-4, 8)])
        cell, record, _ = make_record("w9:0", polygon, {}, lambda x, z: 15.0)
        self.assertEqual(cell, (0, 0))
        self.assertEqual(record[0], "w9:0")
        self.assertLess(min(point[0] for point in record[5][0]), 0.0)
        roof_area = sum(Polygon([record[6][record[7][i + j]] for j in range(3)]).area for i in range(0, len(record[7]), 3))
        self.assertAlmostEqual(roof_area, polygon.area)

    def test_packs_are_deterministic_and_cells_are_independent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = gzip.compress(json.dumps([["w1:0", 4.1]]).encode(), mtime=0)
            second = gzip.compress(json.dumps([["w2:0", 8.0]]).encode(), mtime=0)
            cells = [(0, 0, first), (15, 15, second)]
            write_pack(root / "a.ymb", cells)
            write_pack(root / "b.ymb", list(reversed(cells)))
            self.assertEqual((root / "a.ymb").read_bytes(), (root / "b.ymb").read_bytes())
            self.assertEqual(read_cell(root / "a.ymb", 0, 0), [["w1:0", 4.1]])
            self.assertEqual(read_cell(root / "a.ymb", 15, 15), [["w2:0", 8.0]])
            self.assertEqual(read_cell(root / "a.ymb", 3, 3), [])
            broken = bytearray((root / "a.ymb").read_bytes())
            struct.pack_into("<I", broken, 12, 0)
            (root / "broken.ymb").write_bytes(broken)
            with self.assertRaisesRegex(ValueError, "index"):
                read_cell(root / "broken.ymb", 0, 0)


if __name__ == "__main__":
    unittest.main()
