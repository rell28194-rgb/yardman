extends Node3D
class_name YardmanWeatherFxRuntime

const RAIN_SHADER = preload("res://shaders/rain_streak.gdshader")
const MAX_DROPS := 320
const UPDATE_MATERIAL_INTERVAL := 0.20
const MODES := ["Dynamic", "Clear", "Shower"]
const QUALITY_COUNTS := {
    "Performance": 72,
    "Balanced": 150,
    "Quality": 220,
    "Ultra": 300,
    "Custom": 180,
}

var _mode := "Dynamic"
var _intensity := 0.0
var _rain: MultiMeshInstance3D
var _rain_material: ShaderMaterial
var _materials: Dictionary = {}
var _material_clock := 0.0
var _button: Button
var _layer: CanvasLayer

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_rain_batch()
    _build_ui()
    get_tree().node_added.connect(_on_node_added)
    set_process(true)

func _exit_tree() -> void:
    if _rain != null:
        _rain.multimesh = null
        _rain = null
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
    _update_rain(camera, quality, reduced_motion)
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
    # Low-frequency deterministic pulses provide visual weather continuity.
    # This is a game-weather signal, not a claim about live meteorology.
    var primary := 0.5 + 0.5 * sin(TAU * (wrapped / 7.5 + seed))
    var secondary := 0.5 + 0.5 * sin(TAU * (wrapped / 3.7 + seed * 0.43 + 0.17))
    var gate := smoothstep(0.72, 0.96, primary)
    var texture := 0.62 + secondary * 0.38
    return clampf(gate * texture * 0.82, 0.0, 0.82)

func set_mode(mode: String) -> void:
    if mode not in MODES:
        return
    _mode = mode
    _refresh_button()

func get_mode() -> String:
    return _mode

func debug_state() -> Dictionary:
    var visible := 0
    if _rain != null and _rain.multimesh != null:
        visible = maxi(_rain.multimesh.visible_instance_count, 0)
    return {
        "mode": _mode,
        "intensity": _intensity,
        "rain_batches": 1 if _rain != null else 0,
        "max_drops": MAX_DROPS,
        "visible_drops": visible,
        "tracked_materials": _materials.size(),
    }

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.layer = 40
    add_child(_layer)
    _button = Button.new()
    _button.position = Vector2(534, 18)
    _button.size = Vector2(164, 46)
    _button.focus_mode = Control.FOCUS_NONE
    _button.tooltip_text = "Visual weather simulation: Dynamic / Clear / Shower"
    _button.pressed.connect(_cycle_mode)
    _layer.add_child(_button)
    _refresh_button()

func _cycle_mode() -> void:
    var index := MODES.find(_mode)
    set_mode(MODES[(index + 1) % MODES.size()])

func _refresh_button() -> void:
    if _button == null:
        return
    match _mode:
        "Clear": _button.text = "WEATHER · CLEAR"
        "Shower": _button.text = "WEATHER · RAIN"
        _: _button.text = "WEATHER · AUTO"

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
        var position := Vector3(rng.randf_range(-18.0, 18.0), rng.randf_range(3.0, 25.0), rng.randf_range(-18.0, 18.0))
        var rotation := rng.randf_range(0.0, TAU)
        var scale_value := rng.randf_range(0.78, 1.22)
        var basis := Basis(Vector3.UP, rotation).scaled(Vector3(scale_value, scale_value, scale_value))
        multimesh.set_instance_transform(index, Transform3D(basis, position))
        multimesh.set_instance_custom_data(index, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf_range(0.68, 1.0)))
    multimesh.visible_instance_count = 0
    _rain = MultiMeshInstance3D.new()
    _rain.name = "WeatherRainBatch"
    _rain.multimesh = multimesh
    _rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _rain.visibility_range_end = 55.0
    _rain.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
    add_child(_rain)

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

func _update_rain(camera: Camera3D, quality: String, reduced_motion: bool) -> void:
    if _rain == null or _rain.multimesh == null:
        return
    if camera != null:
        global_position = camera.global_position + Vector3(0.0, 9.0, 0.0)
    var cap := int(QUALITY_COUNTS.get(quality, QUALITY_COUNTS.Balanced))
    if reduced_motion:
        cap = int(round(float(cap) * 0.55))
    var count := clampi(int(round(float(cap) * smoothstep(0.04, 0.82, _intensity))), 0, mini(cap, MAX_DROPS))
    _rain.multimesh.visible_instance_count = count
    _rain.visible = count > 0 and camera != null
    _rain_material.set_shader_parameter("intensity", _intensity)

func _update_environment(game: Node) -> void:
    if game == null:
        return
    var environment = game.get("environment")
    if environment is Environment:
        environment.fog_density = lerpf(0.000020, 0.000115, _intensity)
        environment.fog_sky_affect = lerpf(0.14, 0.38, _intensity)

func _on_node_added(node: Node) -> void:
    if node is MeshInstance3D:
        call_deferred("_track_mesh_instance", node)

func _track_mesh_instance(instance: MeshInstance3D) -> void:
    if not is_instance_valid(instance):
        return
    if instance.material_override is ShaderMaterial:
        _track_material(instance.material_override)
    if instance.mesh != null:
        for surface_index in range(instance.mesh.get_surface_count()):
            var material := instance.mesh.surface_get_material(surface_index)
            if material is ShaderMaterial:
                _track_material(material)

func _track_material(material: ShaderMaterial) -> void:
    if material == null or material.shader == null:
        return
    var path := material.shader.resource_path
    if path not in ["res://shaders/terrain_surface.gdshader", "res://shaders/road_surface.gdshader", "res://shaders/beach.gdshader"]:
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
