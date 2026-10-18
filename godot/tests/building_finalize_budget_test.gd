extends SceneTree

const Building = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_FINALIZE_BUDGET_TEST: " + message)

func _run() -> void:
    var streamer := Building.new()
    streamer._wall_material = StandardMaterial3D.new()
    streamer._roof_material = StandardMaterial3D.new()
    streamer._world_position = Vector2(10000.0, 10000.0) # Keep collision activation out of this publication test.

    var root_node := Node3D.new()
    root_node.name = "SyntheticBuildingCell"
    streamer._build = {
        "key": "0:0",
        "cell": Vector2i.ZERO,
        "root": root_node,
        "records": [],
        "cursor": 0,
        "wall_vertices": PackedVector3Array([Vector3.ZERO, Vector3(0, 1, 0), Vector3(1, 0, 0)]),
        "wall_normals": PackedVector3Array([Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD]),
        "wall_uvs": PackedVector2Array([Vector2.ZERO, Vector2.UP, Vector2.RIGHT]),
        "wall_colors": PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]),
        "wall_uv2s": PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]),
        "wall_indices": PackedInt32Array([0, 1, 2]),
        "roof_vertices": PackedVector3Array([Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(0, 1, 1)]),
        "roof_normals": PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP]),
        "roof_uvs": PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP]),
        "roof_colors": PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]),
        "roof_indices": PackedInt32Array([0, 1, 2]),
        "facades": [],
        "finalize_phase": -1,
        "finalize_step_count": 0,
        "finalize_start_frame": -1,
        "building_count": 0,
        "meshes": [],
        "body": null,
        "collider": null,
        "facade_body": null,
    }

    streamer._prepare_geometry()
    _check(int(streamer._build.finalize_phase) == 0, "geometry completion did not defer publication")
    _check(root_node.get_child_count() == 0, "mesh/scaffold work leaked onto geometry completion frame")
    _check(not streamer._loaded.has("0:0"), "cell published on geometry completion frame")
    _check(streamer._build.records.is_empty(), "compiled source records were retained into finalization")

    streamer._prepare_geometry()
    _check(root_node.get_node_or_null("Walls") != null, "wall upload phase did not create walls")
    _check(root_node.get_node_or_null("Roofs") == null, "roof upload leaked onto wall phase")
    _check(streamer._build.wall_vertices.is_empty() and streamer._build.wall_indices.is_empty(), "wall source arrays were retained after upload")

    streamer._prepare_geometry()
    _check(root_node.get_node_or_null("Roofs") != null, "roof upload phase did not create roofs")
    _check(root_node.get_node_or_null("NearCollision") == null, "physics scaffold leaked onto roof phase")
    _check(streamer._build.roof_vertices.is_empty() and streamer._build.roof_indices.is_empty(), "roof source arrays were retained after upload")

    streamer._prepare_geometry()
    _check(root_node.get_node_or_null("NearCollision") != null, "physics scaffold phase did not create collision nodes")
    _check(not streamer._loaded.has("0:0"), "cell published on physics scaffold phase")

    streamer._prepare_geometry()
    _check(not streamer._loaded.has("0:0"), "cell published on facade integration phase")

    streamer._prepare_geometry()
    _check(streamer._loaded.has("0:0"), "publication phase did not expose completed building cell")
    if streamer._loaded.has("0:0"):
        var ready: Node3D = streamer._loaded["0:0"].root
        _check(bool(ready.get_meta("yardman_budgeted_finalize", false)), "ready cell lacks budgeted-finalize diagnostic marker")
        _check(int(ready.get_meta("yardman_finalize_steps", 0)) == 5, "building finalization collapsed or added hidden publication work")
        _check(streamer._collision_build.is_empty(), "far publication unexpectedly started collision cooking")

    streamer.free()
    if failures == 0:
        print("YARDMAN_BUILDING_FINALIZE_BUDGET_TEST PASS geometry_frame=isolated walls=isolated roofs=isolated physics=isolated facades=isolated publish=isolated source_memory=released")
    quit(0 if failures == 0 else 1)
