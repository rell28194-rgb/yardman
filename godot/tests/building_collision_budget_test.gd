extends SceneTree

const Building = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_COLLISION_BUDGET_TEST: " + message)

func _dense_mesh(triangle_count: int) -> ArrayMesh:
    var vertices := PackedVector3Array()
    var indices := PackedInt32Array()
    for triangle in range(triangle_count):
        var base := vertices.size()
        var x := float(triangle % 100) * 0.02
        var z := float(triangle / 100) * 0.02
        vertices.append(Vector3(x, 0.0, z))
        vertices.append(Vector3(x + 0.01, 1.0, z))
        vertices.append(Vector3(x + 0.02, 0.0, z))
        indices.append_array(PackedInt32Array([base, base + 1, base + 2]))
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _run() -> void:
    var streamer := Building.new()
    streamer.cell_size = 256.0
    streamer.collision_distance = 180.0
    streamer.geometry_budget_us = 1000000
    streamer._world_position = Vector2(128.0, 128.0)

    var cell_root := Node3D.new()
    var body := StaticBody3D.new()
    body.name = "NearCollision"
    body.collision_layer = 0
    var collider := CollisionShape3D.new()
    body.add_child(collider)
    cell_root.add_child(body)
    var mesh := _dense_mesh(1500) # 4,500 indices: forces two bounded face chunks.
    streamer._loaded["0:0"] = {
        "root": cell_root,
        "body": body,
        "collider": collider,
        "meshes": [mesh],
        "count": 1500,
        "facade_body": null,
        "facades": [],
    }

    streamer._refresh_collision()
    _check(collider.shape == null, "collision cooked on activation/start frame")
    _check(str(streamer._collision_build.get("key", "")) == "0:0", "nearest active cell did not start a collision job")
    _check(int(streamer._collision_build.get("phase", -1)) == 0, "start frame performed surface-array acquisition")

    streamer._refresh_collision()
    _check(collider.shape == null, "collision cooked on surface-array acquisition frame")
    _check(int(streamer._collision_build.get("phase", -1)) == 1, "surface arrays did not advance to face expansion")
    _check(int(streamer._collision_build.get("index_cursor", -1)) == 0, "face expansion leaked onto array-acquisition frame")

    streamer._refresh_collision()
    _check(collider.shape == null, "collision cooked during first bounded face chunk")
    _check(int(streamer._collision_build.get("index_cursor", 0)) == Building.COLLISION_FACE_CHUNK, "first face chunk exceeded or missed the fixed bound")
    _check(int(streamer._collision_build.get("face_chunks", 0)) == 1, "first face chunk was not diagnosed")

    streamer._refresh_collision()
    _check(collider.shape == null, "collision cooked on final face-expansion frame")
    _check(int(streamer._collision_build.get("phase", -1)) == 2, "completed faces did not defer BVH cooking")
    _check(int(streamer._collision_build.get("face_chunks", 0)) == 2, "dense mesh did not require the expected two face chunks")

    streamer._refresh_collision()
    _check(collider.shape != null, "isolated BVH-cook frame did not install building collision")
    _check(body.collision_layer == 1, "completed nearby building collider was not activated")
    _check(bool(body.get_meta("yardman_budgeted_collision", false)), "building collider lacks budgeted-collision diagnostic marker")
    _check(int(body.get_meta("yardman_collision_face_chunks", 0)) == 2, "published collision diagnostics lost chunk count")
    _check(streamer._collision_build.is_empty(), "collision build retained temporary face memory after cooking")

    streamer._world_position = Vector2(10000.0, 10000.0)
    streamer._refresh_collision()
    _check(collider.shape == null and body.collision_layer == 0, "retreat did not release the distant physics BVH")

    streamer._world_position = Vector2(128.0, 128.0)
    streamer._refresh_collision()
    _check(not streamer._collision_build.is_empty(), "returning to the cell did not restart collision preparation")
    streamer._world_position = Vector2(10000.0, 10000.0)
    streamer._refresh_collision()
    _check(streamer._collision_build.is_empty(), "retreat did not cancel an in-flight collision job")
    _check(collider.shape == null, "cancelled in-flight job installed stale collision")

    cell_root.free()
    streamer.free()
    if failures == 0:
        print("YARDMAN_BUILDING_COLLISION_BUDGET_TEST PASS activation=deferred arrays=isolated faces=chunked cook=isolated retreat=released cancellation=clean")
    quit(0 if failures == 0 else 1)
