extends Node
class_name YardmanRoadVisibilityRuntime

var _last_distance := 0.0
var _last_meshes := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func apply_render_policy(active: Dictionary) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    var roads = scene.get("roads")
    if roads == null:
        return
    var loaded = roads.get("_loaded")
    if not loaded is Dictionary:
        return
    var distance := clampf(float(active.get("road_visibility", 2200.0)), 600.0, 3800.0)
    _last_meshes = 0
    for tile_root in loaded.values():
        if tile_root is Node3D:
            _last_meshes += apply_to_tile(tile_root as Node3D, distance)
    roads.set("surface_visibility_distance", distance)
    _last_distance = distance

static func apply_to_tile(tile_root: Node3D, distance: float) -> int:
    if tile_root == null:
        return 0
    var safe_distance := clampf(distance, 600.0, 3800.0)
    var changed := 0
    for child in tile_root.get_children():
        if not child is MeshInstance3D:
            continue
        var instance := child as MeshInstance3D
        if instance.name not in [&"paved", &"dirt"]:
            continue
        instance.visibility_range_end = safe_distance
        instance.visibility_range_end_margin = minf(180.0, safe_distance * 0.08)
        instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
        instance.set_meta("yardman_road_visibility", safe_distance)
        changed += 1
    return changed

func runtime_snapshot() -> Dictionary:
    return {"distance": _last_distance, "meshes": _last_meshes}
