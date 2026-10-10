import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import Polygon, box
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_coastline import classify_grid, water_geometry, ShoreDistances, compile_coastline, read_geography


def triangles_geometry(vertices):
    return shapely.union_all([Polygon([(float(p[0]),float(p[2])) for p in vertices[index:index+3]])
                             for index in range(0,len(vertices),3)])


class CoastlineTests(unittest.TestCase):
    def setUp(self):
        self.heights = np.asarray([[2.,12.,5.],[9.,28.,4.],[3.,17.,7.]],dtype="<f4")
        self.land = Polygon([(0.,0.),(128.,0.),(128.,36.),(0.,92.)])

    def test_coastline_not_dem_height_defines_land(self):
        heights = np.full((3,3),1000.,dtype="<f4")
        mask,partial,_ = classify_grid(self.land,heights,0.,0.,64.)
        self.assertEqual(mask[0,0],1)
        self.assertEqual(mask[1,1],0)
        self.assertGreater(len(partial),0)
        self.assertTrue(np.all(partial[:,1] == 1000.))
        # Land at sea level must remain solid, instead of being omitted.
        mask,_,_ = classify_grid(box(0.,0.,128.,128.),np.zeros((3,3)),0.,0.,64.)
        self.assertTrue(np.all(mask == 1))

    def test_partial_land_area_and_terrain_planes(self):
        mask,partial,_ = classify_grid(self.land,self.heights,0.,0.,64.)
        rendered = triangles_geometry(partial)
        full = shapely.union_all([box(x*64,z*64,(x+1)*64,(z+1)*64)
                                  for z in range(2) for x in range(2) if mask[z,x] == 1])
        self.assertLess(shapely.union_all([rendered,full]).symmetric_difference(self.land).area,0.002)
        for triangle in partial.reshape(-1,3,3):
            x,y,z = map(float,triangle.mean(axis=0))
            ix,iz = min(int(x/64),1),min(int(z/64),1)
            u,v = x/64-ix,z/64-iz
            a,b,c,d = map(float,(self.heights[iz,ix],self.heights[iz,ix+1],self.heights[iz+1,ix],self.heights[iz+1,ix+1]))
            expected = a+(b-a)*u+(c-a)*v if u+v <= 1 else d+(c-d)*(1-u)+(b-d)*(1-v)
            self.assertAlmostEqual(y,expected,places=4)

    def test_water_honours_holes_and_no_land_overlap(self):
        island = Polygon([(20.,20.),(110.,20.),(110.,110.),(20.,110.)],holes=[[(40.,40.),(60.,40.),(60.,60.),(40.,60.)]])
        water = water_geometry(island,box(0.,0.,128.,128.),ShoreDistances(island),0.,0.)
        rendered = triangles_geometry(water[:,:3])
        expected = box(0.,0.,128.,128.).difference(island)
        self.assertLess(rendered.symmetric_difference(expected).area,0.002)
        self.assertLess(rendered.intersection(island).area,0.0001)
        self.assertTrue(np.all(water[:,1] == 0.))
        self.assertTrue(np.all((water[:,3] >= 0) & (water[:,3] <= 40)))

    def test_beaches_only_exist_inside_sourced_polygons_and_land(self):
        beach = box(30.,20.,100.,100.)
        _,_,sand = classify_grid(self.land,self.heights,0.,0.,64.,beach)
        rendered = triangles_geometry(sand)
        self.assertLess(rendered.symmetric_difference(beach.intersection(self.land)).area,0.002)
        _,_,empty = classify_grid(self.land,self.heights,0.,0.,64.,Polygon())
        self.assertEqual(len(empty),0)

    def test_coastal_tint_cannot_spread_across_offshore_triangles(self):
        land = box(-1024.,-1024.,0.,1024.)
        water = water_geometry(land,box(0.,-256.,1024.,256.),ShoreDistances(land),0.,0.)
        triangles = water.reshape(-1,3,4)
        coastal = triangles[np.min(triangles[:,:,3],axis=1) < 39.999]
        self.assertGreater(len(coastal),0)
        self.assertLessEqual(float(np.max(coastal[:,:,0])),40.001)
        # At this straight shore, interpolated distances remain real metres.
        np.testing.assert_allclose(coastal[:,:,3],coastal[:,:,0],atol=0.001)
        for triangle in coastal:
            for index in range(3):
                difference = triangle[index,[0,2]]-triangle[(index+1)%3,[0,2]]
                self.assertLessEqual(float(np.linalg.norm(difference)),16.*2**.5+0.001)
        expected = box(0.,-256.,1024.,256.)
        self.assertLess(triangles_geometry(water[:,:3]).symmetric_difference(expected).area,0.002)

    def test_coastal_grid_and_distance_match_neighboring_tile_edges(self):
        land = box(-1024.,-1024.,64.,1024.)
        shore = ShoreDistances(land)
        left = water_geometry(land,box(0.,0.,128.,128.),shore,0.,0.)
        right = water_geometry(land,box(0.,128.,128.,256.),shore,0.,128.)
        a = {(round(float(p[0]),5),round(float(p[3]),5)) for p in left if p[2] == 128.}
        b = {(round(float(p[0]),5),round(float(p[3]),5)) for p in right if p[2] == 0.}
        self.assertEqual(a,b)

    def test_neighbouring_coast_edges_match_height(self):
        heights = np.asarray([[2,12,5,7,9],[9,28,4,8,10],[3,17,7,4,2]],dtype="<f4")
        land = Polygon([(0,0),(256,0),(256,38),(0,110)])
        lm,left,_ = classify_grid(land,heights[:,:3],0.,0.,64.)
        rm,right,_ = classify_grid(land,heights[:,2:],128.,0.,64.)
        def add_full(mask,partial,h):
            vertices = list(partial)
            for z in range(2):
                for x in range(2):
                    if mask[z,x] == 1:
                        vertices.extend(((x*64,h[z,x],z*64),((x+1)*64,h[z,x+1],z*64),
                                         (x*64,h[z+1,x],(z+1)*64),((x+1)*64,h[z+1,x+1],(z+1)*64)))
            return vertices
        left = add_full(lm,left,heights[:,:3])
        right = add_full(rm,right,heights[:,2:])
        l = {(round(float(p[1]),5),round(float(p[2]),5)) for p in left if p[0] == 128.}
        r = {(round(float(p[1]),5),round(float(p[2]),5)) for p in right if p[0] == 0.}
        self.assertEqual(l,r)

    def test_repeatable_compiler_and_binary_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            terrain = root/"terrain"
            terrain.mkdir()
            (terrain/"height_0_0.bin").write_bytes(self.heights.tobytes())
            (terrain/"manifest.json").write_text(json.dumps({"crs":"EPSG:3448","origin":{"easting":1.,"northing":2.},
                "tile_size":128.,"resolution":3,"sample_spacing_m":64.,"tiles":[{"x":0,"z":0,"file":"height_0_0.bin"}]}))
            source = root/"source.pbf"
            source.write_bytes(b"synthetic fixture")
            fixture = (self.land,Polygon(),{"fixture":True})
            first,second = root/"first",root/"second"
            a = compile_coastline(source,terrain,first,fixture)
            b = compile_coastline(source,terrain,second,fixture)
            self.assertEqual(a,b)
            for filename in first.iterdir():
                self.assertEqual(filename.read_bytes(),(second/filename.name).read_bytes())
            self.assertEqual((first/"mask_0_0.bin").stat().st_size,4)
            self.assertEqual((first/"land_0_0.bin").stat().st_size,a["tiles"][0]["land_triangles"]*36)
            self.assertEqual((first/"water_0_0.bin").stat().st_size,a["tiles"][0]["water_triangles"]*48)

    def test_osm_reader_assembles_actual_beach_way_and_closed_coast(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"source.osm"
            path.write_text('''<osm version="0.6" generator="fixture">
<node id="1" lat="18.0" lon="-77.0"/><node id="2" lat="18.0" lon="-76.99"/>
<node id="3" lat="18.01" lon="-76.99"/><node id="4" lat="18.01" lon="-77.0"/>
<node id="5" lat="18.001" lon="-76.999"/><node id="6" lat="18.001" lon="-76.998"/>
<node id="7" lat="18.002" lon="-76.998"/><node id="8" lat="18.002" lon="-76.999"/>
<way id="10"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/><tag k="natural" v="coastline"/></way>
<way id="20"><nd ref="5"/><nd ref="6"/><nd ref="7"/><nd ref="8"/><nd ref="5"/><tag k="natural" v="beach"/></way>
</osm>''')
            land,beach,stats = read_geography(path,{"easting":700000.,"northing":650000.})
            self.assertTrue(land.is_valid)
            self.assertGreater(land.area,1e6)
            self.assertGreater(beach.area,1000.)
            self.assertTrue(land.covers(beach))
            self.assertEqual(stats["coast_ways"],1)
            self.assertEqual(stats["beach_areas"],1)
            self.assertEqual(stats["beach_osm_ids"],[20])

    def test_incomplete_osm_coast_fails_instead_of_guessed_closure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"source.osm"
            path.write_text('''<osm version="0.6"><node id="1" lat="18.0" lon="-77.0"/>
<node id="2" lat="18.01" lon="-77.0"/>
<way id="10"><nd ref="1"/><nd ref="2"/><tag k="natural" v="coastline"/></way></osm>''')
            with self.assertRaisesRegex(ValueError,"not closed"):
                read_geography(path,{"easting":700000.,"northing":650000.})

    def test_corrupt_coastal_dem_rejected_before_packaging(self):
        bad = self.heights.copy()
        bad[1,1] = np.nan
        with self.assertRaisesRegex(ValueError,"Invalid coastal DEM"):
            classify_grid(self.land,bad,0.,0.,64.)
        with self.assertRaisesRegex(ValueError,"Invalid coastal grid"):
            classify_grid(self.land,self.heights,0.,0.,0.)


if __name__ == "__main__":
    unittest.main()
