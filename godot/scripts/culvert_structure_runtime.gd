extends Node3D
class_name YardmanCulvertStructureRuntime

# Visual engineering for reconciled v2 culverts. Crossing position, road width,
# channel width/direction and elevation come from the compiled hydrology pack.
# The structure never changes water, road, terrain, collision or source truth.
const References = preload("res://scripts/reference_assets.gd")
const CONCRETE_ASSET := "building_concrete.png"
const MAX_CULVERTS := 32
const VISIBILITY_END_M := 220.0
const VISIBILITY_FADE_M := 30.0
const ROAD_EDGE_MARGIN_M := 0.30
const HEADWALL_THICKNESS_M := 0.30
const WING_LENGTH_M := 1.35
const WATER_CLEARANCE_M := 0.20

var _hydrology
var _roads
var _material: StandardMaterial3D
var _clock := 0.0
var _signature := ""

func _ready() -> void:
    call_deferred("_bind")

func _process(delta: float) -> void:
    _clock += delta
    if _clock < 0.45:
        return
    _clock = 0.0
    if _hydrology == null or not is_instance_valid(_hydrology) or _roads == null or not is_instance_valid(_roads):
        _bind()
        return
    var next := _state_signature()
    if next != _signature:
        _signature = next
        _rebuild()

func _bind() -> void:
    var root := get_parent()
    if root == null:
        return
    _hydrology = root.get_node_or_null("JamaicaHydrologyRenderer")
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    if _hydrology == null or _roads == null:
        return
    _signature = ""
    _rebuild()
    _signature = _state_signature()

func _state_signature() -> String:
    if _hydrology == null or _roads == null or _roads.coordinates == null:
        return ""
    var keys: Array[String] = []
    for raw: Variant in _hydrology._loaded.keys():
        keys.append(str(raw))
    keys.sort()
    var c = _roads.coordinates
    return "%s|%.1f|%.1f|%d" % [",".join(keys), float(c.render_origin_x), float(c.render_origin_z), int(_hydrology.format_version())]

func _clear() -> void:
    var old := get_node_or_null("ReconciledCulverts")
    if old != null:
        old.free()

func _rebuild() -> void:
    _clear()
    if _hydrology == null or _roads == null or _roads.coordinates == null or int(_hydrology.format_version()) != 2:
        return
    var plans: Array[Dictionary] = []
    var seen: Dictionary = {}
    var loaded_keys: Array[String] = []
    for raw_key: Variant in _hydrology._loaded.keys():
        loaded_keys.append(str(raw_key))
    loaded_keys.sort()
    for key: String in loaded_keys:
        if plans.size() >= MAX_CULVERTS:
            break
        if not _hydrology._tile_files.has(key):
            continue
        var filename := str(_hydrology._tile_files[key])
        if filename.is_empty() or filename.contains("/") or filename.contains("\\") or filename.contains(".."):
            continue
        var path := str(_hydrology.data_root).trim_suffix("/") + "/" + filename
        if not FileAccess.file_exists(path):
            continue
        var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
        if not payload is Dictionary or int(payload.get("format_version", 0)) != 2:
            continue
        var tile_raw: Array = payload.get("tile", [])
        if tile_raw.size() != 2:
            continue
        var tile := Vector2i(int(tile_raw[0]), int(tile_raw[1]))
        var tile_world := Vector2(float(tile.x) * float(_hydrology.tile_size), float(tile.y) * float(_hydrology.tile_size))
        for raw_segment: Variant in payload.get("segments", []):
            if plans.size() >= MAX_CULVERTS:
                break
            if not raw_segment is Array or raw_segment.size() < 20:
                continue
            var segment: Array = raw_segment
            var a := Vector3(tile_world.x + float(segment[0]), float(segment[1]), tile_world.y + float(segment[2]))
            var b := Vector3(tile_world.x + float(segment[3]), float(segment[4]), tile_world.y + float(segment[5]))
            var water_width := clampf(float(segment[9]), 0.7, 45.0)
            if not a.is_finite() or not b.is_finite():
                continue
            var crossings: Array = segment[19] if segment[19] is Array else []
            for raw_crossing: Variant in crossings:
                if plans.size() >= MAX_CULVERTS:
                    break
                if not raw_crossing is Dictionary:
                    continue
                var crossing: Dictionary = raw_crossing
                if not crossing_eligible(crossing):
                    continue
                var identity := crossing_identity(crossing)
                if identity.is_empty() or seen.has(identity):
                    continue
                var plan := culvert_plan(crossing, a, b, water_width)
                if plan.is_empty():
                    continue
                seen[identity] = true
                plans.append(plan)
    if plans.is_empty():
        return

    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    for plan: Dictionary in plans:
        _append_plan(surface, plan)
    surface.generate_normals()
    surface.index()
    var mesh := surface.commit()
    if mesh == null or mesh.get_surface_count() == 0:
        return
    mesh.surface_set_material(0, _concrete_material())
    var instance := MeshInstance3D.new()
    instance.name = "ReconciledCulverts"
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = VISIBILITY_END_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.set_meta("culvert_count", plans.size())
    instance.set_meta("source_contract", "approved reconciled v2 culvert crossing + compiled channel segment + exact road_width_m")
    instance.set_meta("open_aperture", true)
    instance.set_meta("terrain_mutation", false)
    instance.set_meta("water_mutation", false)
    instance.set_meta("road_mutation", false)
    instance.set_meta("collision", false)
    add_child(instance)

func _append_plan(surface: SurfaceTool, plan: Dictionary) -> void:
    var channel: Vector2 = plan.channel_dir
    var side: Vector2 = Vector2(-channel.y, channel.x)
    for mouth: Dictionary in plan.mouths:
        var center_world: Vector3 = mouth.center
        var center_local: Vector3 = _roads.coordinates.world_to_local(center_world.x, center_world.z, center_world.y)
        var height: float = float(plan.headwall_height_m)
        var wall_width: float = float(plan.headwall_width_m)
        var opening_width: float = float(plan.opening_width_m)
        var opening_height: float = float(plan.opening_height_m)
        var post_width := maxf(0.18, (wall_width - opening_width) * 0.5)
        var post_offset := opening_width * 0.5 + post_width * 0.5
        # Two posts and a lintel leave the water opening visibly unobstructed.
        _append_box(surface, center_local + Vector3(side.x, 0.0, side.y) * post_offset,
            side, channel, post_width, height, HEADWALL_THICKNESS_M)
        _append_box(surface, center_local - Vector3(side.x, 0.0, side.y) * post_offset,
            side, channel, post_width, height, HEADWALL_THICKNESS_M)
        var lintel_height := maxf(0.20, height - opening_height)
        var lintel_base := center_local + Vector3.UP * opening_height
        _append_box(surface, lintel_base, side, channel, wall_width, lintel_height, HEADWALL_THICKNESS_M)
        # Wing walls flare away from the road/channel opening. Their plan is
        # deterministic presentation derived from the same channel axis only.
        var outward: Vector2 = channel * float(mouth.outward_sign)
        var wing_center_a: Vector3 = center_local + Vector3(side.x, 0.0, side.y) * (wall_width * 0.5 + 0.18) \
            + Vector3(outward.x, 0.0, outward.y) * (WING_LENGTH_M * 0.42)
        var wing_center_b: Vector3 = center_local - Vector3(side.x, 0.0, side.y) * (wall_width * 0.5 + 0.18) \
            + Vector3(outward.x, 0.0, outward.y) * (WING_LENGTH_M * 0.42)
        _append_box(surface, wing_center_a, side, outward, 0.24, height * 0.72, WING_LENGTH_M)
        _append_box(surface, wing_center_b, side, outward, 0.24, height * 0.72, WING_LENGTH_M)

func _append_box(surface: SurfaceTool, center: Vector3, right2: Vector2, forward2: Vector2,
        width: float, height: float, depth: float) -> void:
    var right := Vector3(right2.x, 0.0, right2.y).normalized() * width * 0.5
    var forward := Vector3(forward2.x, 0.0, forward2.y).normalized() * depth * 0.5
    var down := Vector3(0.0, -height * 0.5, 0.0)
    var up := Vector3(0.0, height * 0.5, 0.0)
    var c := center + Vector3.UP * (height * 0.5)
    var p := [
        c + down - right - forward, c + down + right - forward,
        c + down + right + forward, c + down - right + forward,
        c + up - right - forward, c + up + right - forward,
        c + up + right + forward, c + up - right + forward,
    ]
    for face in [[0,1,5,4], [3,7,6,2], [0,4,7,3], [1,2,6,5], [4,5,6,7], [0,3,2,1]]:
        _quad(surface, p[face[0]], p[face[1]], p[face[2]], p[face[3]])

func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
    for item in [[a, Vector2(0,0)], [b, Vector2(1,0)], [c, Vector2(1,1)], [a, Vector2(0,0)], [c, Vector2(1,1)], [d, Vector2(0,1)]]:
        surface.set_uv(item[1])
        surface.add_vertex(item[0])

func _concrete_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.albedo_color = Color(0.56, 0.56, 0.53)
    _material.roughness = 0.94
    var texture := References.texture(CONCRETE_ASSET)
    if texture != null:
        _material.albedo_texture = texture
        _material.uv1_scale = Vector3(0.55, 0.55, 0.55)
    return _material

static func crossing_eligible(crossing: Dictionary) -> bool:
    return str(crossing.get("status", "unresolved")) == "approved" \
        and str(crossing.get("kind", "unknown")) == "culvert" \
        and is_finite(float(crossing.get("x", NAN))) \
        and is_finite(float(crossing.get("z", NAN))) \
        and float(crossing.get("road_width_m", 0.0)) > 0.0

static func crossing_identity(crossing: Dictionary) -> String:
    if not crossing_eligible(crossing):
        return ""
    return "%d:%d:%s" % [roundi(float(crossing.x) * 10.0), roundi(float(crossing.z) * 10.0), str(crossing.get("road_edge_id", crossing.get("edge_id", "")))]

static func culvert_plan(crossing: Dictionary, a: Vector3, b: Vector3, water_width_m: float) -> Dictionary:
    if not crossing_eligible(crossing) or not a.is_finite() or not b.is_finite() or not is_finite(water_width_m):
        return {}
    var delta := Vector2(b.x - a.x, b.z - a.z)
    var length_sq := delta.length_squared()
    if length_sq < 0.25:
        return {}
    var channel := delta.normalized()
    var crossing_point := Vector2(float(crossing.x), float(crossing.z))
    var segment_a := Vector2(a.x, a.z)
    var t := clampf((crossing_point - segment_a).dot(delta) / length_sq, 0.0, 1.0)
    var nearest := segment_a + delta * t
    if nearest.distance_to(crossing_point) > 1.25:
        return {}
    var road_width := clampf(float(crossing.road_width_m), 1.5, 40.0)
    var water_width := clampf(water_width_m, 0.7, 18.0)
    var elevation := lerpf(a.y, b.y, t) + WATER_CLEARANCE_M
    if not is_finite(elevation):
        return {}
    var mouth_offset := road_width * 0.5 + ROAD_EDGE_MARGIN_M
    var opening_width := clampf(water_width * 0.86, 0.70, 8.5)
    var opening_height := clampf(0.62 + water_width * 0.24, 0.82, 2.25)
    var wall_width := clampf(maxf(water_width + 1.10, opening_width + 0.70), 2.0, 12.0)
    var wall_height := clampf(maxf(1.15, opening_height + 0.38), 1.15, 3.2)
    var mouth_a := crossing_point - channel * mouth_offset
    var mouth_b := crossing_point + channel * mouth_offset
    return {
        "channel_dir": channel,
        "road_width_m": road_width,
        "water_width_m": water_width,
        "headwall_width_m": wall_width,
        "headwall_height_m": wall_height,
        "opening_width_m": opening_width,
        "opening_height_m": opening_height,
        "crossing": crossing_point,
        "source_unchanged": true,
        "mouths": [
            {"center": Vector3(mouth_a.x, elevation, mouth_a.y), "outward_sign": -1.0},
            {"center": Vector3(mouth_b.x, elevation, mouth_b.y), "outward_sign": 1.0},
        ],
    }

static func runtime_contract() -> Dictionary:
    return {
        "format_version": 2,
        "status": "approved",
        "kind": "culvert",
        "max_culverts": MAX_CULVERTS,
        "visibility_m": VISIBILITY_END_M,
        "material_asset": CONCRETE_ASSET,
        "open_aperture": true,
        "terrain_mutation": false,
        "water_mutation": false,
        "road_mutation": false,
        "collision": false,
        "shadows": false,
    }
