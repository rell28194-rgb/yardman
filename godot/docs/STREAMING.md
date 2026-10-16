# Runtime streaming and coordinates

National road JSON is read and parsed on at most two background threads. Nodes, ArrayMesh surfaces and materials are created only on the main thread. Geometry preparation has both a segment cap and a microsecond budget per frame, and mesh batches contain at most 2,048 road polygons. IO is prioritized around the current tile. Work whose target is no longer wanted is discarded; active readers are joined before teardown.

The default load radius is two tiles. One extra retention ring avoids boundary oscillation. Failed resources raise explicit errors and are not repeatedly retried every frame. Readiness is exposed through is_tile_ready and tile_ready. Mesh residency lives in _loaded; topology lives in the separate graph database and remains available after tile unload. Graph partitions have a separate LRU cap.

YardmanCoordinates holds the EPSG origin and render origin in double-precision scalar fields. local_to_world and world_to_local convert only at the nearby rendering boundary. world_to_projected and projected_to_world are exact inverses of the registered local EPSG:3448 mapping. Longitude/latitude projection belongs to the offline PROJ compiler; the runtime does not use a spherical approximation. Negative tiles use floor, never truncation.

rebase_origin(world_x, world_z, world_y) moves road roots and returns the local shift. The owning game applies that shift once to its actors and other world layers. Terrain, saving and gameplay must share the same coordinate object. Rebasing preserves metres, height, tile identity and persistent coordinates.

godot/tests/streaming_test.gd checks national coordinate precision, uncompressed peak-height values, graph lookup/adjacency, national relocation, unload/reload independence, rapid request cancellation, IO caps, bounded residency and teardown. It uses the real generated road dataset.
