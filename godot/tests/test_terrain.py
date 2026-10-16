import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from build_terrain import TerrainSampler, validate_seams
from road_graph import polygon_area

class TerrainTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        # Deliberately non-planar cells prove the triangle split, not just a
        # bilinear plane that would conceal differing physics triangulation.
        heights = np.array([[2, 12, 5, 7, 9], [9, 28, 4, 8, 10], [3, 17, 7, 4, 2]], dtype='<f4')
        entries = []
        for x in (0, 1):
            tile = heights[:, x*2:x*2+3]
            filename = f'height_{x}_0.bin'
            (self.root / filename).write_bytes(tile.tobytes())
            entries.append({'x':x,'z':0,'file':filename})
        self.manifest = {'tile_size':128.,'resolution':3,'sample_spacing_m':64.,'tiles':entries}
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
        self.sampler = TerrainSampler(self.root)
    def tearDown(self):
        self.directory.cleanup()
    def test_exact_neighboring_samples(self):
        validate_seams(self.root, self.manifest)
        for z in (0., 20., 63.5, 64., 100.):
            self.assertAlmostEqual(self.sampler(128.-1e-7,z),self.sampler(128.,z),places=6)
    def test_triangle_matches_collision(self):
        self.assertEqual(self.sampler(16.,16.),6.25)
        self.assertEqual(self.sampler(48.,48.),19.25)
        with self.assertRaises(ValueError):
            self.sampler(-1.,0.)
    def test_road_surface_matches_full_terrain_plane(self):
        polygon = [(20.,0.,20.),(150.,0.,20.),(150.,0.,100.),(20.,0.,100.)]
        surfaces = list(self.sampler.conform_polygon(polygon))
        self.assertGreater(len(surfaces),4)
        self.assertAlmostEqual(sum(polygon_area(p) for p in surfaces),polygon_area(polygon),places=4)
        for surface in surfaces:
            for point in surface:
                self.assertAlmostEqual(point[1],self.sampler(point[0],point[2]),places=5)
            center = tuple(sum(p[axis] for p in surface)/len(surface) for axis in range(3))
            self.assertAlmostEqual(center[1],self.sampler(center[0],center[2]),places=5)

    def test_terrain_clip_preserves_continuous_road_uv(self):
        # Both attributes are affine across this test ribbon. Repeated clipping
        # must preserve them while replacing Y with exact terrain-plane height.
        polygon = [(20., 0., 20., 2., -4.), (150., 0., 20., 15., -4.),
                   (150., 0., 100., 15., 4.), (20., 0., 100., 2., 4.)]
        surfaces = list(self.sampler.conform_polygon(polygon))
        self.assertGreater(len(surfaces), 4)
        for surface in surfaces:
            for x, y, z, station, lateral in surface:
                self.assertAlmostEqual(station, x * 0.1, places=5)
                self.assertAlmostEqual(lateral, (z - 60.) * 0.1, places=5)
                self.assertAlmostEqual(y, self.sampler(x, z), places=5)

if __name__ == '__main__':
    unittest.main()
