# Registered coastline and ocean

The v0.2 unlimited water plane and DEM-height land test produced square coasts,
water through land, and missing sea-level terrain. Land extent now comes from
closed OpenStreetMap `natural=coastline` rings in EPSG:3448. The origin and metre
scale are copied from the compiled terrain manifest. Nested water holes remain
holes. Incomplete coastline rings fail compilation instead of being guessed.

Compile after terrain:

```sh
python godot/tools/build_coastline.py jamaica.osm.pbf godot/data/terrain godot/data/coast
```

Requires Shapely >=2.1 with constrained triangulation, NumPy, pyproj and osmium.
The compiler reads source inputs and writes only its output staging directory.

Each tile stores a row-major `(resolution-1)^2` uint8 mask: 0 means water, 1 a
complete land cell, 2 a partial cell. Full land cells retain the normal DEM
triangles. Partial land uses binary local XYZ triangle lists clipped to the
coastline and the exact same 64m DEM triangle planes. Ocean geometry is the
hole-aware complement of land at canonical elevation 0m. Beach geometry comes
only from assembled OSM `natural=beach` polygons, clipped to land and the same
terrain planes. Missing beaches remain missing; no generic sand belt is added.

`YardmanCoastGeometry.read_tile(root, tile, resolution)` is thread-safe and
returns `mask`, `land`, `water`, `shore_distance`, `beach` packed arrays or an
`error`. An instance configured with the coast root exposes
`load_land_geometry(tile)`. `read_overview(root, width, depth)` returns equivalent
coast clipping for the distant terrain grid. Keep full terrain indices only for
mask value 1 and append the `land` triangle list for partial cells. Use these
same faces for collision. No DEM-height predicate decides land extent.

`JamaicaTerrainStreamer` reads height and coast arrays in the same worker job.
Rendering and collision use full mask-1 cells and the exact partial triangle
lists. `height_at` returns `NAN` outside mapped land, even when the underlying
DSM happens to be above sea level. `is_world_position_ready`, `_loaded`, and
`rebase_by` keep their existing caller contracts.

The distant overview is compiled once into independent 4km visual sectors.
Each sector holds coarse terrain and clipped water. Loading a near terrain tile
hides that entire far sector immediately; unloading reveals it again. This
also covers the retained streaming ring and eliminates coincident near/far
surfaces. Building the overview is spread across the frame budget, and origin
rebases shift a shared far parent exactly once, including sectors assembled
after a rebase. Sector meshes can be culled independently by the renderer.

Ocean colour now uses a geometric band within 40m of the mapped coastline.
That narrow band is tessellated on a global 16m grid; offshore water retains
its 512m grid. Fine preparation occurs in bounded coastal 512m blocks, including
the island overview, rather than allocating a national 16m grid. Previously,
clamping distance samples to 40m at 512m triangle corners stretched coastal
colour hundreds of metres offshore and produced triangular shallow patches.
The new regression test bounds the transition to the actual coast band and
checks matching samples on adjacent tile boundaries. This remains a shoreline
distance colour proxy, not surveyed water depth.

`YardmanCoastline.instantiate_tile(tile, payload, terrain_tile_root, tile_size)`
creates ocean and beach visuals below the terrain tile root, so unloading and
origin rebasing follow the terrain exactly. The terrain tile root represents
sea-level Y=0 before the render-origin offset. Do not also create a giant water
plane. Canonical UVs keep animation stable across origin shifts. Water wave
lighting uses continuous fragment normals and fades at the mapped shore; the
mesh remains at canonical sea-level Y=0, eliminating cracks from differently
tessellated vertex waves at near/far boundaries. Beaches render 3.5cm above the
identical terrain plane to avoid coplanar flicker, without modifying collision.
Sand variation is continuous and derivative-filtered, replacing conspicuous
eight-metre square grain patches in the first coastal GL inspection.

The source manifest records SHA256, OSM attribution, area, geometry counts,
compiled terrain checksum, and limitations. Visual shoreline distance is a
colour input, not measured bathymetry. OSM may omit beaches or contain coastal
errors; the 30m Copernicus DSM may contain canopy or structures. These inputs do
not constitute an authoritative coastal survey.

Tests cover ocean/land exclusion, concave polygons and water holes, zero-height
land, terrain-plane equality, neighbouring coastal heights, sourced sand only,
repeatable output and byte counts.

Validated current source `f31130574377771532733ec91b8a29b066d83e2055bccdc00ab0413bd5a013f3`:
245 coastline ways assembled into 109 closed rings; 80 mapped beach areas.
The compiled terrain envelope contains 1,416 coast tiles, 18,094 partial cells,
100,781 partial-land triangles, 176,586 ocean triangles and 5,572 raw beach
triangles. Runtime skips 63 sand triangles collapsed by float32 rounding.
All tile byte counts and finite fields passed validation; maximum DEM-plane
roundoff was 0.000127m. No ocean triangle centroid lay inside mapped land.
The coastline source also includes offshore cays beyond the current road-based
terrain envelope; its total source area must not be mistaken for runtime
terrain coverage.

`coastline_test.gd` validates binary reads and missing/corrupt inputs.
`terrain_coast_test.gd` validates streaming, zero-height land, matching coastal
collision, off-land height rejection, canonical materials, far-sector exclusion,
origin rebasing and unloading. Both headless tests passed. Visual shader QA and
Android device performance remain separate checks.

`coast_render_test.gd` is an optional actual-GL full-scene inspection. It uses
interior points of sourced Turtle Beach (OSM way 59584393, St. Ann) and Seven
Mile Beach (OSM way 578136135, Westmoreland), records overhead and shoreline
views, and confirms that sea geometry retains its geographic position after
an origin rebase. Set `YARDMAN_COAST_CAPTURE_DIR` to save all six PNGs. It must
run on a GL display; these captures do not establish Android frame rate.
