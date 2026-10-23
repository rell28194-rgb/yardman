extends Node
class_name YardmanBeta1RoadWorkzoneRuntime

# Presentation-only construction equipment. Placement is allowed only on the
# separately compiled OSM highway=construction layer; it never invents road
# works on ordinary roads and never participates in routing or collision.
const References = preload("res://scripts/reference_assets.gd")
const WORK_ZONE_PATH := "res://data/roads/work_zones.json"
const PROP_FILES := {
    "cone": "road_repair_cone.glb",
    "barrier": "road_concrete_barrier.glb",
    "fence": "road_portable_fence.glb",
}
const MAX_SOURCE_SEGMENTS_PER_TILE := 24
const MAX_PROPS_PER_TILE := 96
const CONE_SPACING_M := 10.0
const BARRIER_SPACING_M := 24.0
const FENCE_SPACING_M := 34.0
const LATERAL_OFFSET_M := 2.8
const VISIBILITY_END_M := 150.0
const VISIBILITY_FADE_M := 28.0

var roads: Node
var _records_by_tile: Dictionary = {}
var _meshes: Dictionary = {}
var _loaded_contract := false

func _ready() -> void:
    call_deferred("_bind")

func _exit_tree() -> void:
    if roads != null and is_instance_valid(roads):
        if roads.tile_content_ready.is_connected(_on_road_tile_ready):
            roads.tile_content_ready.disconnect(_on_road_tile_ready)
        if roads.tile_removed.is_connected(_on_road_tile_removed):
            roads.tile_removed.disconnect(_on_road_tile_removed)

func _bind() -> void:
    _load_contract()
    if _records_by_tile.is_empty():
        return
    var root := get_parent()
    if root == null:
        return
    roads = root.get_node_or_null("JamaicaRoadStreamer")
    if roads == null:
        await get_tree().process_frame
        roads = root.get_node_or_null("JamaicaRoadStreamer")
    if roads == null:
        return
    _load_meshes()
    if _meshes.size() != PROP_FILES.size():
        return
    if not roads.tile_content_ready.is_connected(_on_road_tile_ready):
        roads.tile_content_ready.connect(_on_road_tile_ready)
    if not roads.tile_removed.is_connected(_on_road_tile_removed):
        roads.tile_removed.connect(_on_road_tile_removed)
    for raw_key: Variant in roads._loaded.keys():
        var key := str(raw_key)
        var tile := _tile_from_key(key)
        var tile_root := roads._loaded[raw_key] as Node3D
        if tile_root != null:
            _build_tile(tile, tile_root)

func _load_contract() -> void:
    if _loaded_contract:
        return
    _loaded_contract = true
    if not FileAccess.file_exists(WORK_ZONE_PATH):
        return
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORK_ZONE_PATH))
    if not payload is Dictionary or int(payload.get("format", 0)) != 1 \
            or bool(payload.get("routing", true)) or bool(payload.get("collision", true)):
        push_error("Invalid Yardman work-zone presentation contract")
        return
    var sectors: Variant = payload.get("sectors", [])
    if not sectors is Array:
        return
    for raw: Variant in sectors:
        if not raw is Array or raw.size() != 3 or not raw[2] is Array:
            continue
        var tile := Vector2i(int(raw[0]), int(raw[1]))
        _records_by_tile[_tile_key(tile)] = (raw[2] as Array).duplicate(true)

func _load_meshes() -> void:
    if not _meshes.is_empty():
        return
    for kind: String in PROP_FILES:
        var scene: PackedScene = References.scene(str(PROP_FILES[kind]))
        if scene == null:
            _meshes.clear()
            return
        var mesh := _combined_mesh(scene, str(PROP_FILES[kind]))
        if mesh == null:
            _meshes.clear()
            return
        _meshes[kind] = mesh

func _combined_mesh(scene: PackedScene, filename: String) -> ArrayMesh:
    var source := scene.instantiate()
    var output := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, output)
    source.free()
    if output.get_surface_count() == 0:
        return null
    var bounds := output.get_aabb()
    if not bounds.position.is_finite() or not bounds.size.is_finite() \
            or bounds.size.x <= 0.02 or bounds.size.y <= 0.02 or bounds.size.z <= 0.02 \
            or bounds.size.x > 8.0 or bounds.size.y > 5.0 or bounds.size.z > 8.0:
        return null
    var center := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
    var correction := Transform3D(Basis.IDENTITY, -center)
    var grounded := ArrayMesh.new()
    for surface_index in range(output.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(output, surface_index, correction)
        surface.index()
        surface.commit(grounded)
        grounded.surface_set_material(grounded.get_surface_count() - 1, output.surface_get_material(surface_index))
    grounded.set_meta("reference_asset", filename)
    grounded.set_meta("source_shape_preserved", true)
    return grounded

func _collect_surfaces(node: Node, parent_pose: Transform3D, output: ArrayMesh) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                var surface := SurfaceTool.new()
                surface.begin(Mesh.PRIMITIVE_TRIANGLES)
                surface.append_from(instance.mesh, surface_index, pose)
                surface.index()
                surface.commit(output)
                output.surface_set_material(output.get_surface_count() - 1, instance.get_active_material(surface_index))
    for child: Node in node.get_children():
        _collect_surfaces(child, pose, output)

func _on_road_tile_ready(tile: Vector2i, tile_root: Node3D, _segments: Array) -> void:
    _build_tile(tile, tile_root)

func _on_road_tile_removed(_tile: Vector2i) -> void:
    pass

func _build_tile(tile: Vector2i, tile_root: Node3D) -> void:
    var old := tile_root.get_node_or_null("Beta1RoadWorkzone")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    if _meshes.size() != PROP_FILES.size():
        return
    var records: Array = _records_by_tile.get(_tile_key(tile), [])
    if records.is_empty():
        return
    var tile_size := float(roads.tile_size) if roads != null else 4096.0
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var groups := {"cone": [], "barrier": [], "fence": []}
    var accepted := 0
    for index in range(mini(records.size(), MAX_SOURCE_SEGMENTS_PER_TILE)):
        if accepted >= MAX_PROPS_PER_TILE:
            break
        var plans := plans_for_record(records[index], tile_origin, MAX_PROPS_PER_TILE - accepted)
        for plan: Dictionary in plans:
            var kind := str(plan.get("kind", ""))
            if groups.has(kind):
                groups[kind].append(plan)
                accepted += 1
            if accepted >= MAX_PROPS_PER_TILE:
                break
    if accepted == 0:
        return
    var root := Node3D.new()
    root.name = "Beta1RoadWorkzone"
    root.set_meta("source_contract", "OSM highway=construction only")
    root.set_meta("routing", false)
    root.set_meta("collision", false)
    root.set_meta("presentation_inference", true)
    root.set_meta("prop_count", accepted)
    for kind: String in groups:
        var plans: Array = groups[kind]
        if plans.is_empty():
            continue
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.mesh = _meshes[kind]
        multi.instance_count = plans.size()
        for index in range(plans.size()):
            multi.set_instance_transform(index, plans[index].transform)
        var instance := MultiMeshInstance3D.new()
        instance.name = "Workzone_%s" % kind.capitalize()
        instance.multimesh = multi
        instance.visibility_range_end = VISIBILITY_END_M
        instance.visibility_range_end_margin = VISIBILITY_FADE_M
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        instance.set_meta("reference_asset", str(PROP_FILES[kind]))
        root.add_child(instance)
    if root.get_child_count() > 0:
        tile_root.add_child(root)
    else:
        root.free()

static func plans_for_record(record: Dictionary, tile_origin: Vector2, budget: int) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if budget <= 0:
        return result
    var a_raw: Variant = record.get("a", [])
    var b_raw: Variant = record.get("b", [])
    if not a_raw is Array or not b_raw is Array or a_raw.size() < 3 or b_raw.size() < 3:
        return result
    var a := Vector3(float(a_raw[0]), float(a_raw[1]), float(a_raw[2]))
    var b := Vector3(float(b_raw[0]), float(b_raw[1]), float(b_raw[2]))
    if not a.is_finite() or not b.is_finite():
        return result
    var delta2 := Vector2(b.x - a.x, b.z - a.z)
    var length := delta2.length()
    if length < 1.0:
        return result
    var direction := delta2 / length
    var right := Vector2(-direction.y, direction.x)
    var yaw := atan2(-direction.x, -direction.y)
    var seed := str(record.get("id", "workzone")).hash()
    var side := -1.0 if (seed & 1) == 0 else 1.0
    var cone_count := maxi(2, ceili(length / CONE_SPACING_M) + 1)
    for index in range(cone_count):
        if result.size() >= budget:
            return result
        var t := float(index) / float(maxi(cone_count - 1, 1))
        var p := a.lerp(b, t)
        var lateral := right * LATERAL_OFFSET_M * side
        result.append(_plan("cone", p, lateral, tile_origin, yaw, 1.0))
    if length >= 18.0:
        var barrier_count := maxi(1, floori(length / BARRIER_SPACING_M))
        for index in range(barrier_count):
            if result.size() >= budget:
                return result
            var t := (float(index) + 0.5) / float(barrier_count)
            var p := a.lerp(b, t)
            result.append(_plan("barrier", p, right * LATERAL_OFFSET_M * side, tile_origin, yaw, 1.0))
    if length >= 28.0:
        var fence_count := maxi(1, floori(length / FENCE_SPACING_M))
        for index in range(fence_count):
            if result.size() >= budget:
                return result
            var t := (float(index) + 0.5) / float(fence_count)
            var p := a.lerp(b, t)
            result.append(_plan("fence", p, right * LATERAL_OFFSET_M * -side, tile_origin, yaw, 1.0))
    return result

static func _plan(kind: String, point: Vector3, lateral: Vector2, tile_origin: Vector2,
        yaw: float, scale_value: float) -> Dictionary:
    var local := Vector3(point.x + lateral.x - tile_origin.x, point.y + 0.025,
        point.z + lateral.y - tile_origin.y)
    var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_value)
    return {"kind": kind, "transform": Transform3D(basis, local),
        "canonical": Vector3(point.x + lateral.x, point.y, point.z + lateral.y),
        "source_only": true}

static func _tile_key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

static func _tile_from_key(key: String) -> Vector2i:
    var parts := key.split(":")
    if parts.size() != 2:
        return Vector2i(2147483647, 2147483647)
    return Vector2i(int(parts[0]), int(parts[1]))

static func asset_contract() -> Dictionary:
    return {
        "files": PROP_FILES.duplicate(),
        "source": "OSM highway=construction only",
        "work_zone_file": WORK_ZONE_PATH,
        "max_source_segments_per_tile": MAX_SOURCE_SEGMENTS_PER_TILE,
        "max_props_per_tile": MAX_PROPS_PER_TILE,
        "visibility_m": VISIBILITY_END_M,
        "routing": false,
        "collision": false,
        "shadows": false,
        "ordinary_road_placement": false,
        "asset_absent_fallback": true,
    }
