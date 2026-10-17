extends SceneTree

class FakeTerrain:
    extends Node
    var tile_size: float = 4096.0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("ROAD_EARTHWORK_GEOMETRY_TEST: " + message)
    quit(1)

func _run() -> void:
    var helper = load("res://scripts/road_earthwork_geometry.gd").new()
    helper.terrain = FakeTerrain.new()
    var source_record := {
        "id": "w1:0:source_cutting",
        "classification": "source_cutting",
        "a": [100.0, 10.0, 100.0],
        "b": [140.0, 11.0, 100.0],
        "right": [0.0, 1.0],
        "road_half_width_m": 4.0,
        "outer_half_width_m": 10.0,
        "mask_half_width_m": 11.0,
        "outer_left_y": [14.0, 15.0],
        "outer_right_y": [12.5, 13.5],
    }
    var prepared: Array = helper._prepare_records(Vector2i.ZERO, [source_record])
    if prepared.size() != 1:
        _fail("source cutting did not prepare exactly one runtime corridor")
        return
    if absf(float(prepared[0]["a_y"]) - 9.96) > 0.001:
        _fail("road seam drop was not applied")
        return
    if not helper._inside_any(Vector2(120.0, 100.0), prepared):
        _fail("corridor center was not inside source earthwork mask")
        return
    if helper._inside_any(Vector2(120.0, 140.0), prepared):
        _fail("far terrain was incorrectly inside source earthwork mask")
        return

    var tile_root := Node3D.new()
    var land := MeshInstance3D.new()
    land.name = "RegisteredLand"
    var tool := SurfaceTool.new()
    tool.begin(Mesh.PRIMITIVE_TRIANGLES)
    tool.add_vertex(Vector3(0.0, 0.0, 0.0))
    tool.add_vertex(Vector3(4096.0, 0.0, 0.0))
    tool.add_vertex(Vector3(0.0, 0.0, 4096.0))
    var mesh := tool.commit()
    var material := ShaderMaterial.new()
    material.shader = load("res://shaders/terrain_surface.gdshader")
    mesh.surface_set_material(0, material)
    land.mesh = mesh
    tile_root.add_child(land)

    if not helper._apply_mask(tile_root, prepared):
        _fail("actual terrain shader mask could not bind")
        return
    if not bool(material.get_shader_parameter("road_earthwork_mask_enabled")):
        _fail("source earthwork terrain mask was not enabled")
        return

    helper._build_replacement_mesh(tile_root, prepared)
    var replacement := tile_root.get_node_or_null("RegisteredRoadEarthworks")
    if replacement == null:
        _fail("replacement earthwork geometry was not built")
        return
    var slopes := replacement.get_node_or_null("RoadCutFillSlopes") as MeshInstance3D
    if slopes == null or slopes.mesh == null or slopes.mesh.get_faces().size() != 12:
        _fail("replacement did not contain exactly four side-slope triangles")
        return
    var collision := replacement.get_node_or_null("RoadEarthworkCollision") as StaticBody3D
    if collision == null or collision.get_child_count() != 1:
        _fail("replacement collision was not built")
        return

    # A DEM-only candidate must never survive runtime preparation, even if a
    # malformed data file somehow contains it.
    var forbidden := source_record.duplicate(true)
    forbidden["classification"] = "dem_sidehill_candidate"
    if not helper._prepare_records(Vector2i.ZERO, [forbidden]).is_empty():
        _fail("DEM-only candidate leaked into runtime earthwork geometry")
        return

    print("YARDMAN_ROAD_EARTHWORK_GEOMETRY_TEST PASS source_only=1 mask=1 slopes=4 collision=1")
    tile_root.free()
    helper.terrain.free()
    helper.free()
    quit(0)
