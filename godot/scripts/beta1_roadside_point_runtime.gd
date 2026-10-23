extends Node
class_name YardmanBeta1RoadsidePointRuntime

# Explicit national OSM point truth owns position. Recovered Beta1 assets are
# presentation-only; orientation may face the nearest compiled road but spacing
# and infrastructure existence are never inferred here.
const References = preload("res://scripts/reference_assets.gd")
const BuiltEnvironment = preload("res://scripts/near_field_built_environment_runtime.gd")
const DATA_PATH := "res://data/roads/roadside_points.json"
const PROP_FILES := {
    "street_lamp": "road_lamp_single_arm.glb",
    "bus_shelter": "road_bus_stop_shelter.glb",
}
const ROAD_ORIENTATION_SEARCH_M := 32.0
const MAX_POINTS_PER_TILE := 32
const VISIBILITY_END_M := 190.0
const VISIBILITY_FADE_M := 28.0

var roads: Node
var terrain: Node
var _sectors: Dictionary = {}
var _meshes: Dictionary = {}
var _loaded_contract := false

func _ready() -> void:
    call_deferred("_bind")

func _exit_tree() -> void:
    if roads != null and is_instance_valid(roads) and roads.tile_content_ready.is_connected(_on_road_tile_ready):
        roads.tile_content_ready.disconnect(_on_road_tile_ready)

func _bind() -> void:
    var root := get_parent()
    if root == null:
        return
    roads = root.get_node_or_null("JamaicaRoadStreamer")
    terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    if roads == null or terrain == null:
        await get_tree().process_frame
        roads = root.get_node_or_null("JamaicaRoadStreamer")
        terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    if roads == null or terrain == null:
        return
    _load_contract()
    _load_meshes()
    if not _loaded_contract or _meshes.is_empty():
        return
    if not roads.tile_content_ready.is_connected(_on_road_tile_ready):
        roads.tile_content_ready.connect(_on_road_tile_ready)
    for raw_key: Variant in roads._loaded.keys():
        var key := str(raw_key)
        var tile_root: Variant = roads._loaded[raw_key]
        if tile_root is Node3D and _sectors.has(key):
            _build_tile(_tile_from_key(key), tile_root as Node3D)

func _load_contract() -> void:
    if not FileAccess.file_exists(DATA_PATH):
        return
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
    if not payload is Dictionary:
        return
    var data: Dictionary = payload
    if int(data.get("format", 0)) != 1 or not bool(data.get("geographic_authority", false)) \
            or bool(data.get("routing", true)) or bool(data.get("navigation", true)) \
            or bool(data.get("collision", true)) or bool(data.get("inferred_spacing", true)):
        return
    var tile_size := float(data.get("tile_size", 0.0))
    if not is_finite(tile_size) or tile_size <= 0.0:
        return
    for raw: Variant in data.get("sectors", []):
        if not raw is Array or raw.size() != 3 or not raw[2] is Array:
            continue
        var tile := Vector2i(int(raw[0]), int(raw[1]))
        var accepted: Array = []
        for record_raw: Variant in raw[2]:
            if record_raw is Dictionary and not point_plan(record_raw as Dictionary).is_empty():
                accepted.append((record_raw as Dictionary).duplicate(true))
        if not accepted.is_empty():
            _sectors[_tile_key(tile)] = accepted
    _loaded_contract = true

func _load_meshes() -> void:
    for kind: String in PROP_FILES:
        var packed: PackedScene = References.scene(str(PROP_FILES[kind]))
        if packed == null:
            continue
        var mesh := _combined_mesh(packed, str(PROP_FILES[kind]))
        if mesh != null:
            _meshes[kind] = mesh

func _combined_mesh(packed: PackedScene, filename: String) -> ArrayMesh:
    var source := packed.instantiate()
    var raw := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, raw)
    source.free()
    if raw.get_surface_count() == 0:
        return null
    var bounds := raw.get_aabb()
    if not bounds.position.is_finite() or not bounds.size.is_finite() \
            or bounds.size.x < 0.05 or bounds.size.y < 0.10 or bounds.size.z < 0.05 \
            or bounds.size.x > 8.0 or bounds.size.y > 12.0 or bounds.size.z > 8.0:
        return null
    var center := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
    var correction := Transform3D(Basis.IDENTITY, -center)
    var baked := ArrayMesh.new()
    for surface_index in range(raw.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(raw, surface_index, correction)
        surface.index()
        surface.commit(baked)
        baked.surface_set_material(baked.get_surface_count() - 1, raw.surface_get_material(surface_index))
    baked.set_meta("reference_asset", filename)
    baked.set_meta("source_scale_preserved", true)
    return baked

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
    if _sectors.has(_tile_key(tile)):
        _build_tile(tile, tile_root)

func _build_tile(tile: Vector2i, tile_root: Node3D) -> void:
    var old := tile_root.get_node_or_null("Beta1RoadsidePoints")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    var records: Array = _sectors.get(_tile_key(tile), [])
    if records.is_empty() or _meshes.is_empty():
        return
    var tile_size := float(roads.tile_size)
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var groups := {"street_lamp": [], "bus_shelter": []}
    var accepted := 0
    for raw: Variant in records:
        if accepted >= MAX_POINTS_PER_TILE or not raw is Dictionary:
            break
        var base_plan := point_plan(raw as Dictionary)
        if base_plan.is_empty():
            continue
        var kind := str(base_plan.get("kind", ""))
        if not _meshes.has(kind):
            continue
        var canonical: Vector2 = base_plan.get("point", Vector2(INF, INF))
        if not canonical.is_finite():
            continue
        var candidates: Dictionary = roads._nearby_surface_segments(
            canonical.x, canonical.y, ROAD_ORIENTATION_SEARCH_M)
        var nearest: Dictionary = BuiltEnvironment._nearest_road(canonical, candidates.values())
        if kind == "bus_shelter" and nearest.is_empty():
            # Shelter geometry is meaningful only when a compiled road can
            # establish its facing. The source point itself remains retained.
            continue
        var basis := orientation_basis(canonical, nearest, str(base_plan.get("source_id", "")))
        var y := float(terrain.height_at(canonical.x, canonical.y))
        if not is_finite(y) or y < -50.0:
            continue
        var local := Vector3(canonical.x - tile_origin.x, y + 0.025, canonical.y - tile_origin.y)
        groups[kind].append(Transform3D(basis, local))
        accepted += 1
    if accepted == 0:
        return
    var root := Node3D.new()
    root.name = "Beta1RoadsidePoints"
    root.set_meta("source_contract", "explicit OSM point sidecar")
    root.set_meta("position_inference", false)
    root.set_meta("orientation_inference", true)
    root.set_meta("routing", false)
    root.set_meta("navigation", false)
    root.set_meta("collision", false)
    root.set_meta("prop_count", accepted)
    for kind: String in groups:
        var poses: Array = groups[kind]
        if poses.is_empty() or not _meshes.has(kind):
            continue
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.mesh = _meshes[kind]
        multi.instance_count = poses.size()
        for index in range(poses.size()):
            multi.set_instance_transform(index, poses[index])
        var instance := MultiMeshInstance3D.new()
        instance.name = "RoadsidePoint_%s" % kind.capitalize()
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

static func point_plan(record: Dictionary) -> Dictionary:
    var kind := str(record.get("kind", ""))
    if kind not in ["street_lamp", "bus_shelter"]:
        return {}
    var position: Array = record.get("position", [])
    if position.size() < 3:
        return {}
    var point := Vector2(float(position[0]), float(position[2]))
    if not point.is_finite():
        return {}
    var tags: Dictionary = record.get("source_tags", {}) if record.get("source_tags", {}) is Dictionary else {}
    if kind == "street_lamp" and str(tags.get("highway", "")).to_lower() != "street_lamp":
        return {}
    if kind == "bus_shelter":
        if str(tags.get("highway", "")).to_lower() != "bus_stop" \
                or str(tags.get("shelter", "")).to_lower() not in ["yes", "true", "1"]:
            return {}
    return {"kind": kind, "point": point, "source_id": str(record.get("id", "")),
        "position_inference": false}

static func orientation_basis(point: Vector2, nearest_road: Dictionary, source_id: String) -> Basis:
    var facing := Vector2.ZERO
    var road_point: Variant = nearest_road.get("point", null)
    if road_point is Vector2 and (road_point as Vector2).is_finite():
        facing = (road_point as Vector2) - point
    if facing.length_squared() < 0.01:
        # Source tags establish the point but commonly omit mount direction.
        # Stable fallback rotation changes no geographic position.
        var bucket := posmod(source_id.hash(), 16)
        var yaw := float(bucket) / 16.0 * TAU
        facing = Vector2(sin(yaw), cos(yaw))
    else:
        facing = facing.normalized()
    var forward := Vector3(facing.x, 0.0, facing.y).normalized()
    var right := Vector3.UP.cross(forward).normalized()
    var basis := Basis(right, Vector3.UP, forward)
    if basis.determinant() < 0.0:
        basis = Basis(-right, Vector3.UP, forward)
    return basis

static func _tile_key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

static func _tile_from_key(key: String) -> Vector2i:
    var parts := key.split(":")
    if parts.size() != 2:
        return Vector2i.ZERO
    return Vector2i(int(parts[0]), int(parts[1]))

static func asset_contract() -> Dictionary:
    return {
        "data_path": DATA_PATH,
        "files": PROP_FILES.duplicate(),
        "source_contract": "explicit OSM point tags only",
        "position_inference": false,
        "orientation_inference": true,
        "max_points_per_tile": MAX_POINTS_PER_TILE,
        "visibility_m": VISIBILITY_END_M,
        "source_scale_preserved": true,
        "routing": false,
        "navigation": false,
        "collision": false,
        "terrain_mutation": false,
        "asset_absent_fallback": true,
        "data_absent_fallback": true,
    }
