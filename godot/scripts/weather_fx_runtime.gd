extends Node3D
class_name YardmanWeatherFxRuntime

const RAIN_SHADER = preload("res://shaders/rain_streak.gdshader")
const MIST_SHADER = preload("res://shaders/weather_mist.gdshader")
const MAX_DROPS := 620
const MAX_MIST := 28
const UPDATE_MATERIAL_INTERVAL := 0.20
const MODES := ["Dynamic", "Clear", "Shower"]
const QUALITY_COUNTS := {
    "Performance": 120,
    "Balanced": 260,
    "Quality": 400,
    "Ultra": 560,
    "Custom": 320,
}
const QUALITY_MIST_COUNTS := {
    "Performance": 4,
    "Balanced": 10,
    "Quality": 16,
    "Ultra": 24,
    "Custom": 12,
}
# Numeric behavior recovered from the owner's Beta 2 Tropico APK. These are
# source-reference parameters only: Yardman uses its own shader/meshes and a
# much smaller Android-safe budget rather than importing foreign world content.
const TROPICO_RAIN_REFERENCE := {
    "RainNear": {"max_live": 1000, "life_min": 1.0, "life_max": 2.0, "velocity_min": 20.0, "velocity_max": 30.0},
    "RainMiddle": {"max_live": 1500, "life_min": 2.0, "life_max": 2.0, "velocity_min": 20.0, "velocity_max": 30.0},
    "RainFar": {"max_live": 2500, "life_min": 1.5, "life_max": 1.5, "velocity_min": 30.0, "velocity_max": 30.0},
    "RainMist": {"max_live": 200, "life_min": 3.0, "life_max": 4.0, "size_min": 20.0, "size_max": 50.0},
    "MistAfterRain": {"max_live": 1000, "life_min": 3.0, "life_max": 6.0, "size_min": 15.0, "size_max": 20.0},
}
const WETTABLE_SHADERS := [
    "res://shaders/terrain_surface.gdshader",
    "res://shaders/road_surface.gdshader",
    "res://shaders/beach.gdshader",
    "res://shaders/building_surface.gdshader",
]

var _mode := "Dynamic"
var _intensity := 0.0
var _after_rain := 0.0
var _rain: MultiMeshInstance3D
var _rain_material: ShaderMaterial
var _mist: MultiMeshInstance3D
var _mist_material: ShaderMaterial
var _materials: Dictionary = {}
var _material_clock := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_rain_batch()
    _build_mist_batch()
    # Weather mode remains programmatically controllable through set_mode(), but
    # it no longer owns a top-level HUD button. Engineering controls belong in
    # the game's consolidated menu rather than covering normal gameplay.
    get_tree().node_added.connect(_on_node_added)
    set_process(true)

func _exit_tree() -> void:
    var tree := get_tree()
    if tree != null and tree.node_added.is_connected(_on_node_added):
        tree.node_added.disconnect(_on_node_added)
    if _rain != null:
        _rain.multimesh = null
        _rain = null
    if _mist != null:
        _mist.multimesh = null
        _mist = null
    _materials.clear()

func _process(delta: float) -> void:
    var safe_delta := clampf(delta, 0.0, 0.25) if is_finite(delta) else 0.016
    var game := get_tree().current_scene if get_tree() != null else null
    var target := 0.0
    var quality := "Balanced"
    var reduced_motion := false
    var camera: Camera3D = null
    if game != null:
        var visuals = game.get("visuals")
        if visuals != null:
            quality = str(visuals.get("quality"))
        var touch = game.get("touch")
        if touch != null:
            var settings = touch.get("settings")
            if settings is Dictionary:
                reduced_motion = bool(settings.get("reduced_motion", false))
        camera = game.get("camera") as Camera3D
        if bool(game.get("world_ready")):
            target = target_intensity(float(game.get("day_hour")), str(game.get("current_parish")))
    _intensity = move_toward(_intensity, target, safe_delta * (0.55 if target > _intensity else 0.38))
    _intensity = clampf(_intensity, 0.0, 1.0)
    if _intensity >= 0.18:
        _after_rain = maxf(_after_rain, _intensity)
    else:
        _after_rain = move_toward(_after_rain, 0.0, safe_delta * 0.045)
    _update_rain(camera, quality, reduced_motion)
    _update_mist(camera, quality, reduced_motion)
    _update_environment(game)
    _material_clock += safe_delta
    if _material_clock >= UPDATE_MATERIAL_INTERVAL:
        _material_clock = 0.0
        _apply_wetness()

func target_intensity(hour: float, stable_region: String) -> float:
    match _mode:
        "Clear":
            return 0.0
        "Shower":
            return 0.78
        _:
            return dynamic_intensity(hour, stable_region)

static func dynamic_intensity(hour: float, stable_region: String) -> float:
    if not is_finite(hour):
        return 0.0
    var wrapped := fposmod(hour, 24.0)
    var seed := float(absi(stable_region.hash()) % 10000) / 10000.0
    var primary := 0.5 + 0.5 * sin(TAU * (wrapped / 7.5 + seed))
    var secondary := 0.5 + 0.5 * sin(TAU * (wrapped / 3.7 + seed * 0.43 + 0.17))
    var gate := smoothstep(0.72, 0.96, primary)
    var texture := 0.62 + secondary * 0.38
    return clampf(gate * texture * 0.82, 0.0, 0.82)

static func rain_tier_for_index(index: int) -> float:
    # Interleave every ten instances so reduced visible_instance_count values
    # retain the recovered 20/30/50 near/mid/far live-count relationship.
    var bucket := posmod(index, 10)
    if bucket < 2:
        return 0.0
    if bucket < 5:
        return 0.5
    return 1.0

static func weather_contract() -> Dictionary:
    return {
        "source": "Beta2 Tropico-v1-4-2RC1-fix.apk particle behavior",
        "source_reference": TROPICO_RAIN_REFERENCE.duplicate(true),
        "rain_batches": 1,
        "mist_batches": 1,
        "max_draw_batches": 2,
        "max_drops": MAX_DROPS,
        "max_mist": MAX_MIST,
        "raw_source_live_total": 5000,
        "runtime_geometry_authority": false,
        "terrain_mutation": false,
        "foreign_texture_dependency": false,
    }

func set_mode(mode: String) -> void:
    if mode not in MODES:
        return
    _mode = mode

func get_mode() -> String:
    return _mode

func debug_state() -> Dictionary:
    var visible := 0
    var visible_mist := 0
    if _rain != null and _rain.multimesh != null:
        visible = maxi(_rain.multimesh.visible_instance_count, 0)
    if _mist != null and _mist.multimesh != null:
        visible_mist = maxi(_mist.multimesh.visible_instance_count, 0)
    return {
        "mode": _mode,
        "intensity": _intensity,
        "after_rain": _after_rain,
        "rain_batches": 1 if _rain != null else 0,
        "mist_batches": 1 if _mist != null else 0,
        "weather_batches": (1 if _rain != null else 0) + (1 if _mist != null else 0),
        "max_drops": MAX_DROPS,
        "max_mist": MAX_MIST,
        "visible_drops": visible,
        "visible_mist": visible_mist,
        "tracked_materials": _materials.size(),
        "standalone_ui": 0,
        "wettables": WETTABLE_SHADERS.size(),
    }

func _build_rain_batch() -> void:
    _rain_material = ShaderMaterial.new()
    _rain_material.shader = RAIN_SHADER
    _rain_material.set_shader_parameter("intensity", 0.0)
    var drop_mesh := _make_drop_mesh()
    drop_mesh.surface_set_material(0, _rain_material)
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_custom_data = true
    multimesh.mesh = drop_mesh
    multimesh.instance_count = MAX_DROPS
    var rng := RandomNumberGenerator.new()
    rng.seed = 281940721
    for index in range(MAX_DROPS):
        var tier := rain_tier_for_index(index)
        var angle := rng.randf_range(0.0, TAU)
        var radius := 0.0
        var height := 0.0
        var scale_value := 1.0
        if tier < 0.25:
            radius = rng.randf_range(3.0, 18.0)
            height = rng.randf_range(2.0, 24.0)
            scale_value = rng.randf_range(0.95, 1.26)
        elif tier < 0.75:
            radius = rng.randf_range(13.0, 32.0)
            height = rng.randf_range(5.0, 29.0)
            scale_value = rng.randf_range(0.78, 1.02)
        else:
            radius = rng.randf_range(25.0, 48.0)
            height = rng.randf_range(8.0, 34.0)
            scale_value = rng.randf_range(0.58, 0.82)
        var position := Vector3(cos(angle) * radius, height, sin(angle) * radius)
        var rotation := rng.randf_range(0.0, TAU)
        var basis := Basis(Vector3.UP, rotation).scaled(Vector3(scale_value, scale_value, scale_value))
        multimesh.set_instance_transform(index, Transform3D(basis, position))
        multimesh.set_instance_custom_data(index, Color(rng.randf(), rng.randf(), tier, rng.randf_range(0.68, 1.0)))
    multimesh.visible_instance_count = 0
    _rain = MultiMeshInstance3D.new()
    _rain.name = "WeatherRainHierarchy"
    _rain.multimesh = multimesh
    _rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _rain.visibility_range_end = 62.0
    _rain.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
    add_child(_rain)

func _build_mist_batch() -> void:
    _mist_material = ShaderMaterial.new()
    _mist_material.shader = MIST_SHADER
    _mist_material.set_shader_parameter("intensity", 0.0)
    var mist_mesh := _make_mist_mesh()
    mist_mesh.surface_set_material(0, _mist_material)
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_custom_data = true
    multimesh.mesh = mist_mesh
    multimesh.instance_count = MAX_MIST
    var rng := RandomNumberGenerator.new()
    rng.seed = 281940923
    for index in range(MAX_MIST):
        var angle := rng.randf_range(0.0, TAU)
        var radius := rng.randf_range(8.0, 40.0)
        var position := Vector3(cos(angle) * radius, rng.randf_range(-8.5, -2.5), sin(angle) * radius)
        var scale_value := rng.randf_range(0.75, 1.55)
        var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3(scale_value, scale_value, scale_value))
        multimesh.set_instance_transform(index, Transform3D(basis, position))
        multimesh.set_instance_custom_data(index, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf_range(0.55, 0.88)))
    multimesh.visible_instance_count = 0
    _mist = MultiMeshInstance3D.new()
    _mist.name = "WeatherRainMist"
    _mist.multimesh = multimesh
    _mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _mist.visibility_range_end = 72.0
    _mist.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
    add_child(_mist)

func _make_drop_mesh() -> ArrayMesh:
    var width := 0.012
    var length := 0.78
    var vertices := PackedVector3Array([
        Vector3(-width, 0.0, 0.0), Vector3(width, 0.0, 0.0), Vector3(width, length, 0.0), Vector3(-width, length, 0.0),
        Vector3(0.0, 0.0, -width), Vector3(0.0, 0.0, width), Vector3(0.0, length, width), Vector3(0.0, length, -width),
    ])
    var uvs := PackedVector2Array([
        Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
        Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
    ])
    var indices := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _make_mist_mesh() -> ArrayMesh:
    var half_width := 7.0
    var height := 4.5
    var vertices := PackedVector3Array([
        Vector3(-half_width, 0.0, 0.0), Vector3(half_width, 0.0, 0.0), Vector3(half_width, height, 0.0), Vector3(-half_width, height, 0.0),
        Vector3(0.0, 0.0, -half_width), Vector3(0.0, 0.0, half_width), Vector3(0.0, height, half_width), Vector3(0.0, height, -half_width),
    ])
    var uvs := PackedVector2Array([
        Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
        Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
    ])
    var indices := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _update_rain(camera: Camera3D, quality: String, reduced_motion: bool) -> void:
    if _rain == null or _rain.multimesh == null:
        return
    if camera != null:
        global_position = camera.global_position + Vector3(0.0, 8.0, 0.0)
    var cap := int(QUALITY_COUNTS.get(quality, QUALITY_COUNTS.Balanced))
    if reduced_motion:
        cap = int(round(float(cap) * 0.55))
    var count := clampi(int(round(float(cap) * smoothstep(0.04, 0.82, _intensity))), 0, mini(cap, MAX_DROPS))
    _rain.multimesh.visible_instance_count = count
    _rain.visible = count > 0 and camera != null
    _rain_material.set_shader_parameter("intensity", _intensity)

func _update_mist(camera: Camera3D, quality: String, reduced_motion: bool) -> void:
    if _mist == null or _mist.multimesh == null:
        return
    var cap := int(QUALITY_MIST_COUNTS.get(quality, QUALITY_MIST_COUNTS.Balanced))
    if reduced_motion:
        cap = maxi(1, int(round(float(cap) * 0.55)))
    var post_rain := _after_rain * (1.0 - smoothstep(0.08, 0.42, _intensity)) * 0.52
    var strength := clampf(maxf(_intensity * 0.70, post_rain), 0.0, 1.0)
    var count := clampi(int(round(float(cap) * smoothstep(0.10, 0.72, strength))), 0, mini(cap, MAX_MIST))
    _mist.multimesh.visible_instance_count = count
    _mist.visible = count > 0 and camera != null
    _mist_material.set_shader_parameter("intensity", strength)

func _update_environment(game: Node) -> void:
    if game == null:
        return
    var environment = game.get("environment")
    if environment is Environment:
        var post_rain_fog := _after_rain * (1.0 - smoothstep(0.12, 0.50, _intensity))
        var fog_strength := clampf(maxf(_intensity, post_rain_fog * 0.45), 0.0, 1.0)
        environment.fog_density = lerpf(0.000020, 0.000125, fog_strength)
        environment.fog_sky_affect = lerpf(0.14, 0.40, fog_strength)

func _on_node_added(node: Node) -> void:
    if node is MeshInstance3D:
        call_deferred("_track_mesh_instance", weakref(node))

func _track_mesh_instance(reference) -> void:
    var instance = reference.get_ref() if reference is WeakRef else reference
    if instance == null or not is_instance_valid(instance) or not instance is MeshInstance3D:
        return
    var mesh_instance := instance as MeshInstance3D
    if mesh_instance.material_override is ShaderMaterial:
        _track_material(mesh_instance.material_override)
    if mesh_instance.mesh != null:
        for surface_index in range(mesh_instance.mesh.get_surface_count()):
            var material := mesh_instance.mesh.surface_get_material(surface_index)
            if material is ShaderMaterial:
                _track_material(material)

func _track_material(material: ShaderMaterial) -> void:
    if material == null or material.shader == null:
        return
    var path := material.shader.resource_path
    if path not in WETTABLE_SHADERS:
        return
    _materials[material.get_instance_id()] = weakref(material)
    material.set_shader_parameter("weather_wetness", _intensity)

func _apply_wetness() -> void:
    var stale: Array = []
    for id in _materials.keys():
        var reference = _materials[id]
        var material = reference.get_ref() if reference is WeakRef else null
        if not material is ShaderMaterial:
            stale.append(id)
            continue
        material.set_shader_parameter("weather_wetness", _intensity)
    for id in stale:
        _materials.erase(id)
