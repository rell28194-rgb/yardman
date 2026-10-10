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

`YardmanCoastline.instantiate_tile(tile, payload, terrain_tile_root, tile_size)`
creates ocean and beach visuals below the terrain tile root, so unloading and
origin rebasing follow the terrain exactly. The terrain tile root represents
sea-level Y=0 before the render-origin offset. Do not also create a giant water
plane. Canonical UVs keep animation stable across origin shifts. Water wave
amplitude fades to zero at the mapped shore. Beaches render 3.5cm above the
identical terrain plane to avoid coplanar flicker, without modifying collision.

The source manifest records SHA256, OSM attribution, area, geometry counts,
compiled terrain checksum, and limitations. Visual shoreline distance is a
colour input, not measured bathymetry. OSM may omit beaches or contain coastal
errors; the 30m Copernicus DSM may contain canopy or structures. These inputs do
not constitute an authoritative coastal survey.

Tests cover ocean/land exclusion, concave polygons and water holes, zero-height
land, terrain-plane equality, neighbouring coastal heights, sourced sand only,
repeatable output and byte counts.
