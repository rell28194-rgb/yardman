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
    var publication_streamer := Building.new()
    publication_streamer.cell_size = 256.0
    publication_streamer.collision_distance = 180.0
    publication_streamer._world_position = Vector2(128.0, 128.0)
    var publication_root := Node3D.new()
    var publication_body := StaticBody3D.new()
    publication_body.name = "NearCollision"
    publication_body.collision_layer = 0
    var publication_collider := CollisionShape3D.new()
    publication_body.add_child(publication_collider)
    publication_root.add_child(publication_body)
    var publication_mesh := _dense_mesh(1)
    publication_streamer._build = {
        "root": publication_root,
        "cell": Vector2i.ZERO,
        "key": "0:0",
        "building_count": 1,
        "meshes": [publication_mesh],
        "body": publication_body,
        "collider": publication_collider,
        "facade_body": null,
        "facades": [],
        "finalize_step_count": 5,
        "finalize_start_frame": Engine.get_process_frames(),
    }
    publication_streamer._publish_cell()
    _check(publication_streamer._collision_build.is_empty(), "cell publication consumed collision scheduler work outside the frame owner")
    publication_streamer._refresh_collision()
    _check(str(publication_streamer._collision_build.get("key", "")) == "0:0", "single explicit collision refresh did not start the published near cell")
    _check(int(publication_streamer._collision_build.get("phase", -1)) == 0, "first explicit collision refresh advanced beyond job start")
    publication_streamer.free()

    # The shared RenderRuntime building budget must cover both geometry/finalize
    # and physics preparation. When both are pending, exactly one heavy lane may
    # advance per frame; alternate ownership prevents either lane starving.
    var contention := Building.new()
    contention.cell_size = 256.0
    contention.collision_distance = 180.0
    contention.geometry_budget_us = 1000000
    contention._world_position = Vector2(128.0, 128.0)
    var collision_root := Node3D.new()
    var collision_body := StaticBody3D.new()
    collision_body.collision_layer = 0
    var collision_collider := CollisionShape3D.new()
    collision_body.add_child(collision_collider)
    collision_root.add_child(collision_body)
    var contention_mesh := _dense_mesh(1)
    contention._loaded["0:0"] = {
        "root": collision_root,
        "body": collision_body,
        "collider": collision_collider,
        "meshes": [contention_mesh],
        "count": 1,
        "facade_body": null,
        "facades": [],
    }
    contention._start_collision_build("0:0")
    var finalize_root := Node3D.new()
    contention._build = {
        "root": finalize_root,
        "cell": Vector2i(1, 0),
        "key": "1:0",
        "records": [],
        "facades": [],
        "meshes": [],
        "finalize_phase": 2,
        "finalize_step_count": 0,
        "finalize_start_frame": Engine.get_process_frames(),
        "body": null,
        "collider": null,
        "facade_body": null,
    }
    contention._advance_stream_integration(true)
    _check(int(contention._build.get("finalize_phase", -1)) == 3, "geometry lane did not receive first shared building integration turn")
    _check(int(contention._collision_build.get("phase", -1)) == 0, "collision advanced in the same turn as building finalize")
    contention._advance_stream_integration(true)
    _check(int(contention._build.get("finalize_phase", -1)) == 3, "building finalize advanced in collision-owned turn")
    _check(int(contention._collision_build.get("phase", -1)) == 1, "collision lane did not receive alternating shared integration turn")
    contention._build.clear()
    contention._loaded.clear()
    finalize_root.free()
    collision_root.free()
    contention.free()

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
        print("YARDMAN_BUILDING_COLLISION_BUDGET_TEST PASS publication=single_owner aggregate=shared_turns activation=deferred arrays=isolated faces=chunked cook=isolated retreat=released cancellation=clean")
    quit(0 if failures == 0 else 1)