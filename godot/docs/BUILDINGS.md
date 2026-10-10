# Real-footprint building layer

The national compiler uses **OpenStreetMap building areas**. It produces original extruded meshes with generic procedural facades; it does not borrow proprietary game assets or claim surveyed Jamaican architecture.

## Source and geometry

`build_buildings.py` reads the PBF with `osmium.SimpleHandler.apply_file(..., locations=True)`. Its area callback uses `osmium.geom.WKBFactory.create_multipolygon(area)`, preserving multipolygon courtyard rings. The footprint is transformed into EPSG:3448 using the terrain/road manifest origin. X is east, Z is south and elevation remains in real metres.

Stable part IDs are `w<OSM way id>:<part>` or `r<OSM relation id>:<part>`. Parts are sorted deterministically. Exactly identical normalized footprints are suppressed with a SQLite geometry digest. Each entire footprint part belongs to one 256 m content cell. A seam-crossing building retains its full geometry once rather than being independently recreated on both sides.

Wall bases split at terrain grid edges and triangle diagonals. Interpolated bases therefore follow the same piecewise-linear surface as the DEM renderer/collider across their entire length. Roofs are horizontal at the highest sampled foundation elevation plus building height. Shapely constrained Delaunay triangulation preserves holes, including courtyard roofs. This does not create measured interior floors or doors.

Height precedence is explicit in every record:

1. A valid source `height` value in metres or feet.
2. Source `building:levels` × 3.15 m + 0.35 m; storey height is inferred.
3. A declared building-class estimate, default 4.4 m.

Foundation elevations inherit the Copernicus DSM's limitations. They are not surveyed bare-earth building levels. Generic facade windows, colours and roof materials are inferred original presentation.

## Storage and bounded ingestion

Footprints are spooled to SQLite with a 16 MiB page-cache target. The compiler never retains a national list of building records. The output contains a metadata manifest and one binary pack per occupied 4096 m tile.

Each `YMB1` pack contains:

| Field | Encoding |
| --- | --- |
| Magic and populated-cell count | `<4sI>` |
| Per-cell index | `<HHII>`: local cell X/Z, byte offset, compressed byte length |
| Payload | Independent gzip stream, `mtime=0`, compact JSON array |

Cells have local addresses 0–15. Negative world tile/cell addressing uses floor division. Payload records are `[source_id, height, height_source, kind, roof_elevation, rings, roof_vertices, roof_triangle_indices]`. Ring vertices contain cell-relative X/Z and canonical Y; roof vertices contain cell-relative X/Z. Heights and geometry are unchanged by origin rebasing.

The compiler stages output and retains the previous compiled dataset if ingestion fails. It rejects invalid/uncovered areas with counted reasons, suppresses exact duplicates, and excludes footprint parts below one square metre. Raw cell payloads are capped at 32 MiB. The manifest records source hash, attribution, bounds, height-source totals and actual maximum cell sizes.

## Runtime

`building_streamer.gd` exposes:

- `configure(data_root, coordinates, terrain)` before adding the node.
- `target`, `update_world(x, z, force=false)`, and `rebase_by(shift)`.
- `quality`, `draw_distance`, `collision_distance`, `max_loaded_cells`.
- `is_idle()` / `inflight_count()`; these include pending nearby collision preparation.
- `set_surface_materials(walls, roofs)` accepts imported `StandardMaterial3D` or `ShaderMaterial` resources before startup or during streaming. The resources are copied once per layer; their textures remain shared. Changing materials updates existing merged cell surfaces without modifying the registered footprints, roof elevations, foundations or collision geometry. Passing `null` restores the declared fallback for that layer.

It seeks and decompresses only nearby cell payloads using two capped IO threads. Stale work is discarded after travel, and cell roots unload outside the desired range. Main-thread geometry preparation is limited to 20 buildings or 1.8 ms per frame. Each cell merges its walls and roofs into two meshes; geometry is capped at 400,000 vertices per cell.

Default visible distances and maximum residency are 450 m/64 cells (Performance), 800 m/96 (Balanced), 1100 m/144 (Quality) and 1450 m/192 (Ultra). Visibility, content residency and near collision are separate. Physics BVHs exist only near the actor, are prepared one per pass, and are discarded when distant while render meshes may remain visible. World collision layer 1 allows walking and driving to contact the structures.

Imported materials do not need the fallback shader's `visibility_distance` uniform. Existing mesh visibility ranges change with the quality setting, so replacing a fallback with an imported material retains the same mobile residency and draw-distance controls. The material input is a connection point for authorized reference art; an input resource alone does not establish that the graphics target has been met. No reference-game materials were available locally when this connection was added.

## Verified national snapshot

The first full compile from the current Jamaica PBF produced:

- 1,022,944 building footprint parts in 714 packs and 63,195 content cells.
- 243 courtyard rings and 3,022,058 roof triangles.
- 60 source heights; 4,408 heights derived from source levels; 1,018,476 declared inferred heights.
- 216 rejected source areas, 53 duplicate parts and 41 sub-square-metre parts.
- Largest cell: 358 buildings and 103,597 uncompressed JSON bytes.
- Building pack bytes: 121,308,996; metadata: 3,031,036 bytes.

Most source rejections encountered during that compile were outside the current mainland DEM coverage; invalid OSM area assembly is also rejected. The aggregate count is authoritative for that snapshot; newer compiles include categorized rejection counts. This is a national footprint layer, not a claim of surveyed height coverage or completed building art.

## Compile and tests

```
python godot/tools/build_buildings.py /tmp/jamaica.osm.pbf godot/data/terrain godot/data/buildings
python -m unittest discover -s godot/tests -p test_buildings.py -v
godot --headless --path godot --script res://tests/building_streamer_test.gd
```

The Python suite covers height precedence, courtyard-safe triangulation, exact terrain-triangle foundation conformance, whole-building seam ownership and deterministic independent cell packs. The runtime suite checks merged meshes, nearby collision, distant BVH release/recreation, far-load cancellation, origin rebasing, negative addressing, resource bounds and malformed pack rejection. It also verifies that imported materials survive travel, can be replaced without changing geometry or adding nodes, and preserve live mesh visibility bounds.

Official implementation references: [Pyosmium geometry factory](https://docs.osmcode.org/pyosmium/latest/reference/Geometry-Functions/) and [Shapely constrained triangulation](https://shapely.readthedocs.io/en/2.1.2/reference/shapely.constrained_delaunay_triangles.html).
