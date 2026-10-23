extends Node
class_name YardmanBeta1WorkZoneRuntime

const References = preload("res://scripts/reference_assets.gd")
const DATA_PATH := "res://data/roads/work_zones.json"
const PROP_FILES := {
    "cone": "road_repair_cone.glb",
    "barrier": "road_concrete_barrier.glb",
    "fence": "road_portable_fence.glb",
}
const CONE_STEP_M := 8.0
const CONE_EDGE_CLEARANCE_M := 0.65
const MAX_CONES_PER_SEGMENT := 12
const MAX_PROPS_PER_TILE := 48
const VISIBILITY_END_M := 145.0
const VISIBILITY_FADE_M := 24.0

var roads: Node
var terrain: Node
var _sectors: Dictionary = {}
var _meshes: Dictionary = {}
var _loaded_contract := false

func _ready() -> void:
    call_deferred("_bind")

func _exit_tree() -> void:
    if roads != null and is_instance_valid(roads):
        if roads.tile_content_ready.is_connected(_on_road_tile_ready):
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
        var tile_root = roads._loaded[raw_key]
        if tile_root is Node3D and _sectors.has(key):
            _build_tile(_tile_from_key(key), tile_root as Node3D)

func _load_contract() -> void:
    if not FileAccess.file_exists(DATA_PATH):
        return
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
    if not payload is Dictionary:
        return
    var data: Dictionary = payload
    if int(data.get("format", 0)) != 1 or bool(data.get("drivable", true)) \
            or bool(data.get("navigation", true)):
        return
    var tile_size := float(data.get("tile_size", 0.0))
    if not is_finite(tile_size) or tile_size <= 0.0:
        return
    for raw: Variant in data.get("sectors", []):
        if not raw is Array or raw.size() != 3 or not raw[2] is Array:
            continue
        var tile := Vector2i(int(raw[0]), int(raw[1]))
        _sectors[_tile_key(tile)] = (raw[2] as Array).duplicate(true)
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
            or bounds.size.x < 0.05 or bounds.size.y < 0.05 or bounds.size.z < 0.05 \
            or bounds.size.x > 15.0 or bounds.size.y > 5.0 or bounds.size.z > 5.0:
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
    var old := tile_root.get_node_or_null("Beta1WorkZones")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    var records: Array = _sectors.get(_tile_key(tile), [])
    if records.is_empty() or _meshes.is_empty():
        return
    var tile_size := float(roads.tile_size)
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var groups := {"cone": [], "barrier": [], "fence": []}
    var accepted := 0
    for raw: Variant in records:
        if accepted >= MAX_PROPS_PER_TILE or not raw is Dictionary:
            break
        var plans := placement_plan(raw as Dictionary)
        for plan: Dictionary in plans:
            if accepted >= MAX_PROPS_PER_TILE:
                break
            var kind := str(plan.get("kind", ""))
            if not _meshes.has(kind):
                continue
            var canonical: Vector2 = plan.get("point", Vector2(INF, INF))
            if not canonical.is_finite():
                continue
            var y := float(terrain.height_at(canonical.x, canonical.y))
            if not is_finite(y) or y < -50.0:
                continue
            var basis: Basis = plan.get("basis", Basis.IDENTITY)
            var local := Vector3(canonical.x - tile_origin.x, y + 0.025, canonical.y - tile_origin.y)
            groups[kind].append(Transform3D(basis, local))
            accepted += 1
    if accepted == 0:
        return
    var root := Node3D.new()
    root.name = "Beta1WorkZones"
    root.set_meta("source_contract", "OSM highway=construction sidecar")
    root.set_meta("presentation_inference", true)
    root.set_meta("drivable", false)
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
        instance.name = "WorkZone_%s" % kind.capitalize()
        instance.multimesh = multi
        instance.visibility_range_end = VISIBILITY_END_M
        instance.visibility_range_end_margin = VISIBILITY_FADE_M
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        instance.set_meta("reference_asset", str(PROP_FILES[kind]))
        # Preserve the authoritative CPU placement contract for optional visual
        # variants. Headless/dummy renderers do not reliably round-trip MultiMesh
        # transforms, so downstream presentation layers must never infer source
        # anchors by reading renderer-owned instance buffers back.
        instance.set_meta("source_poses", poses.duplicate(true))
        instance.set_meta("source_pose_count", poses.size())
        root.add_child(instance)
    if root.get_child_count() > 0:
        tile_root.add_child(root)
    else:
        root.free()

static func placement_plan(record: Dictionary) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var a3: Array = record.get("a", [])
    var b3: Array = record.get("b", [])
    if a3.size() < 3 or b3.size() < 3:
        return result
    var a := Vector2(float(a3[0]), float(a3[2]))
    var b := Vector2(float(b3[0]), float(b3[2]))
    if not a.is_finite() or not b.is_finite():
        return result
    var delta := b - a
    var length_m := delta.length()
    if not is_finite(length_m) or length_m < 2.0:
        return result
    var direction := delta / length_m
    var right := Vector2(-direction.y, direction.x)
    var width := clampf(float(record.get("width_m", 5.8)), 2.5, 20.0)
    var cone_offset := width * 0.5 + CONE_EDGE_CLEARANCE_M
    var cone_count := mini(MAX_CONES_PER_SEGMENT, maxi(2, int(floor(length_m / CONE_STEP_M)) + 1))
    for index in range(cone_count):
        var t := float(index) / float(maxi(cone_count - 1, 1))
        var side := -1.0 if (index & 1) == 0 else 1.0
        var point := a.lerp(b, t) + right * cone_offset * side
        var yaw := atan2(direction.x, direction.y)
        result.append({"kind": "cone", "point": point, "basis": Basis(Vector3.UP, yaw)})

    var access := str(record.get("access", "unknown")).to_lower()
    if access in ["no", "private"]:
        var closure_kind := "barrier" if width >= 5.0 else "fence"
        # Recovered barrier/fence meshes run along local X, so align X across
        # the road. Source metre scale is preserved; no stretched fake barricade.
        var cross_axis := Vector3(right.x, 0.0, right.y).normalized()
        var forward_axis := Vector3(direction.x, 0.0, direction.y).normalized()
        var closure_basis := Basis(cross_axis, Vector3.UP, forward_axis)
        if closure_basis.determinant() < 0.0:
            closure_basis = Basis(-cross_axis, Vector3.UP, forward_axis)
        result.append({"kind": closure_kind, "point": a, "basis": closure_basis})
        result.append({"kind": closure_kind, "point": b, "basis": closure_basis})
    return result

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
        "source_tag": "highway=construction",
        "access_closure_only": true,
        "max_props_per_tile": MAX_PROPS_PER_TILE,
        "visibility_m": VISIBILITY_END_M,
        "source_scale_preserved": true,
        "cpu_pose_metadata": true,
        "drivable": false,
        "navigation": false,
        "collision": false,
        "terrain_mutation": false,
        "asset_absent_fallback": true,
        "data_absent_fallback": true,
    }
