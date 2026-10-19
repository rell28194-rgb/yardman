extends SceneTree

# Synthetic fixture only: verifies scheduling/lifetime semantics, never packaged
# or counted as sourced world/visual acceptance.
const Corridor = preload("res://scripts/road_corridor_terrain_runtime.gd")
var failures := 0

class FixtureTerrain extends Node3D:
    var tile_size := 128.0
    var spacing := 64.0
    var resolution := 3
    var _height_data := {"0:0": PackedFloat32Array([30,30,30,30,30,30,30,30,30])}
    var _coast_data := {"0:0": {"mask": PackedByteArray([1,1,1,1])}}
    var requested := 0
    func _tile_key(x: int, z: int) -> String:
        return "%d:%d" % [x,z]
    func is_tile_ready(_tile: Vector2i) -> bool:
        return get_node_or_null("TerrainTile_0_0") != null
    func request_corridor_integration(_runtime: Node) -> void:
        requested += 1
    func cancel_corridor_integration(_runtime: Node) -> void:
        pass

func _initialize() -> void:
    _run.call_deferred()

func _run() -> void:
    var terrain := FixtureTerrain.new()
    root.add_child(terrain)
    var tile_root := _tile_fixture()
    terrain.add_child(tile_root)
    var runtime := Corridor.new()
    root.add_child(runtime)
    runtime.set_process(false)
    runtime._terrain = terrain
    var land := tile_root.get_node("RegisteredLand") as MeshInstance3D
    var body := tile_root.get_node("FixtureBody") as StaticBody3D
    var collider := body.get_node("FixtureShape") as CollisionShape3D
    var original := land.mesh
    var original_shape := collider.shape
    var road := [0.0,32.0,64.0,32.0,8.0,5,0,"road",0,10.0,10.0,
        [[0.0,10.0,28.0],[0.0,10.0,36.0],[64.0,10.0,36.0],[64.0,10.0,28.0]]]
    runtime._on_road_tile(Vector2i.ZERO, tile_root, [road])
    _require(terrain.requested == 1, "signal must register shared terrain budget work")
    _require(land.mesh == original and collider.shape == original_shape and runtime._task_id < 0,
        "road-ready signal synchronously started geometry/resource work")
    _require(runtime.advance_terrain_integration(0), "zero grant must retain pending work")
    _require(runtime._task_id < 0, "zero budget launched work")
    runtime.advance_terrain_integration(500)
    _require(runtime._task_id >= 0, "grant failed to launch CPU worker")
    # Changes made by the physics bubble while CPU work runs must survive commit.
    body.collision_layer = 0
    body.collision_mask = 4
    collider.disabled = true
    await _drain(runtime)
    _require(land.mesh != original and land.has_meta("road_corridor_refined"), "staged job never committed")
    _require(body.collision_layer == 0 and body.collision_mask == 4 and collider.disabled,
        "refinement reactivated or replaced physics-bubble collider")
    var plan := runtime.refinement_plan([road], Vector2i.ZERO, 128.0, 64.0, 3, terrain._coast_data["0:0"].mask)
    var reference := runtime.rebuild_land_arrays(original, terrain._height_data["0:0"], plan.cells, Vector2i.ZERO, 128.0, 64.0, 3)
    var expected_mesh := ArrayMesh.new()
    expected_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, reference.arrays)
    var expected := expected_mesh.surface_get_arrays(0)
    var actual := land.mesh.surface_get_arrays(0)
    for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_INDEX]:
        _require(actual[channel] == expected[channel], "worker changed deterministic geometry channel %d" % channel)
    var expected_faces := PackedVector3Array()
    var reference_vertices: PackedVector3Array = reference.arrays[Mesh.ARRAY_VERTEX]
    for index in reference.arrays[Mesh.ARRAY_INDEX]:
        expected_faces.append(reference_vertices[index])
    _require(collider.shape.get_faces() == expected_faces, "worker collision face expansion differs from reference")
    runtime._on_road_tile_removed(Vector2i.ZERO)
    _require(land.mesh != original, "road eviction synchronously rebuilt collision/restored mesh")
    await _drain(runtime)
    _require(land.mesh == original and not land.has_meta("road_corridor_refined"), "road eviction did not restore original surface")
    _require(body.collision_layer == 0 and collider.disabled, "restoration reactivated collision")
    # Cancel CPU results when road content changes while work is in flight.
    runtime._on_road_tile(Vector2i.ZERO, tile_root, [road])
    runtime.advance_terrain_integration(500)
    runtime._on_road_tile_removed(Vector2i.ZERO)
    await _drain(runtime)
    _require(land.mesh == original, "stale road worker committed after road eviction")
    # Cancel a completed upload too: a tile can be evicted/reloaded at any stage.
    runtime._on_road_tile(Vector2i.ZERO, tile_root, [road])
    runtime.advance_terrain_integration(500)
    while runtime._task_id >= 0 and not WorkerThreadPool.is_task_completed(runtime._task_id):
        await process_frame
    runtime.advance_terrain_integration(500)
    _require(runtime._job.has("mesh"), "fixture failed to reach staged mesh upload")
    runtime._on_terrain_tile_removed(Vector2i.ZERO)
    terrain.remove_child(tile_root)
    var replacement := _tile_fixture()
    terrain.add_child(replacement)
    var new_land := replacement.get_node("RegisteredLand") as MeshInstance3D
    var replacement_original := new_land.mesh
    await _drain(runtime)
    _require(new_land.mesh == replacement_original, "stale uploaded result attached to replacement terrain root")
    runtime._on_terrain_tile(Vector2i.ZERO)
    await _drain(runtime)
    _require(new_land.has_meta("road_corridor_refined"), "replacement terrain readiness failed to schedule fresh refinement")
    runtime._on_road_tile_removed(Vector2i.ZERO)
    await _drain(runtime)
    _require(new_land.mesh == replacement_original, "replacement tile restored previous root's source mesh")
    _require(runtime.runtime_snapshot().cancelled_jobs >= 2, "stale suppression counter did not record cancellations")
    print("CORRIDOR_STAGING_METRICS ", runtime.runtime_snapshot())
    tile_root.free()
    runtime.free()
    terrain.free()
    if failures == 0:
        print("YARDMAN_ROAD_CORRIDOR_STAGING_TEST PASS worker_parity deferred_signals cancellation restoration collision_state")
    quit(0 if failures == 0 else 1)

func _drain(runtime: Node) -> void:
    for step in range(2000):
        if not runtime.advance_terrain_integration(500):
            return
        await process_frame
    _require(false, "staged work did not converge within fixture timeout")

func _tile_fixture() -> Node3D:
    var tile_root := Node3D.new()
    tile_root.name = "TerrainTile_0_0"
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    for z in range(3):
        for x in range(3):
            vertices.append(Vector3(x * 64.0, 30.0, z * 64.0))
            normals.append(Vector3.UP)
            colors.append(Color.WHITE)
    for z in range(2):
        for x in range(2):
            var a := z * 3 + x
            indices.append_array(PackedInt32Array([a,a+1,a+3,a+1,a+4,a+3]))
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var land := MeshInstance3D.new()
    land.name = "RegisteredLand"
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    land.mesh = mesh
    tile_root.add_child(land)
    var body := StaticBody3D.new()
    body.name = "FixtureBody"
    var collider := CollisionShape3D.new()
    collider.name = "FixtureShape"
    collider.shape = mesh.create_trimesh_shape()
    body.add_child(collider)
    tile_root.add_child(body)
    return tile_root

func _require(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("YARDMAN_ROAD_CORRIDOR_STAGING_TEST FAIL " + message)
