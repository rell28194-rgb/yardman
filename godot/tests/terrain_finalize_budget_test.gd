extends SceneTree

const Terrain = preload("res://scripts/terrain_streamer.gd")
var failures := 0

class FakeCoastline:
    extends Node3D
    var calls := 0

    func instantiate_tile(_tile: Vector2i, _coast: Dictionary, parent: Node3D, _tile_size: float) -> void:
        calls += 1
        var marker := Node3D.new()
        marker.name = "BudgetedCoastMarker"
        parent.add_child(marker)

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("TERRAIN_FINALIZE_BUDGET_TEST: " + message)

func _has_static_body(node: Node) -> bool:
    for child in node.get_children():
        if child is StaticBody3D:
            return true
    return false

func _run() -> void:
    var terrain := Terrain.new()
    terrain.set_process(false)
    terrain.resolution = 3
    terrain.spacing = 1.0
    terrain.tile_size = 2.0
    terrain.geometry_budget_us = 1000000
    terrain._terrain_material = StandardMaterial3D.new()
    var coast := FakeCoastline.new()
    terrain.coastline = coast
    terrain.add_child(coast)
    root.add_child(terrain)

    var tile_root := Node3D.new()
    tile_root.name = "SyntheticTerrainTile"
    terrain._building = {
        "key": "0:0",
        "tile": Vector2i.ZERO,
        "root": tile_root,
        "heights": PackedFloat32Array([0,0,0,0,0,0,0,0,0]),
        "coast": {"mask": PackedByteArray([1,1,1,1]), "land": PackedVector3Array()},
        "cursor": 0,
        "land_cursor": 0,
        "vertices": PackedVector3Array(),
        "indices": PackedInt32Array(),
        "normals": PackedVector3Array(),
        "colors": PackedColorArray(),
        "finalize_phase": -1,
        "finalize_step_count": 0,
        "finalize_start_frame": -1,
        "collision_cursor": 0,
        "collision_faces": PackedVector3Array(),
        "collision_face_chunks": 0,
    }

    terrain._prepare_geometry()
    _check(int(terrain._building.finalize_phase) == 0, "geometry completion did not defer finalization")
    _check(tile_root.get_child_count() == 0, "mesh/collision/coast work leaked onto the geometry completion frame")

    terrain._prepare_geometry()
    _check(tile_root.get_node_or_null("RegisteredLand") != null, "mesh phase did not install rendered land")
    _check(not _has_static_body(tile_root), "collision cook ran on the mesh-upload phase")
    _check(coast.calls == 0, "coastline instantiation ran on the mesh-upload phase")

    terrain._prepare_geometry()
    _check(not _has_static_body(tile_root), "collision shape cooked while face expansion was still the active phase")
    _check(int(terrain._building.collision_face_chunks) == 1, "collision faces were not expanded through the bounded chunk path")

    terrain._prepare_geometry()
    _check(_has_static_body(tile_root), "collision shape phase did not install terrain physics")
    _check(coast.calls == 0, "coastline work was not isolated from collision cooking")

    terrain._prepare_geometry()
    _check(coast.calls == 1, "coastline phase did not run exactly once")
    _check(not terrain._loaded.has("0:0"), "tile published before coastline integration completed")

    terrain._prepare_geometry()
    _check(terrain._loaded.has("0:0"), "final publish phase did not expose the ready terrain tile")
    if terrain._loaded.has("0:0"):
        var ready: Node3D = terrain._loaded["0:0"]
        _check(bool(ready.get_meta("yardman_budgeted_finalize", false)), "ready tile lacks budgeted-finalize diagnostic marker")
        _check(int(ready.get_meta("yardman_finalize_steps", 0)) >= 5, "terrain integration collapsed back into too few finalize steps")
        _check(int(ready.get_meta("yardman_collision_face_chunks", 0)) == 1, "ready tile lost collision-chunk diagnostics")

    terrain.queue_free()
    if failures == 0:
        print("YARDMAN_TERRAIN_FINALIZE_BUDGET_TEST PASS geometry_frame=isolated mesh=isolated collision_faces=chunked collision_cook=isolated coast=isolated publish=isolated")
    quit(0 if failures == 0 else 1)
