extends Node

# Creates a tiny off-screen render pass before Android gameplay so the material
# variants most likely to be selected by quality/thermal changes are exercised
# up front instead of on their first visible world frame.
const Registry = preload("res://scripts/render_material_registry.gd")

var status := "idle"
var renderer := ""
var warmed_paths: Array[String] = []
var _viewport: SubViewport
var _frames_remaining := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(false)

func _process(_delta: float) -> void:
    if status != "warming":
        return
    _frames_remaining -= 1
    if _frames_remaining <= 0:
        _finish()

static func planned_shader_paths(renderer_family: String) -> Array[String]:
    var safe: Array[String] = [
        Registry.ROAD_SAFE.resource_path,
        Registry.WATER_SAFE.resource_path,
        Registry.TERRAIN_SAFE.resource_path,
    ]
    if renderer_family in ["gles", "gl_compatibility", "opengl3"]:
        return safe
    var result: Array[String] = [
        Registry.ROAD_HIGH.resource_path,
        Registry.WATER_HIGH.resource_path,
        Registry.TERRAIN_HIGH.resource_path,
    ]
    result.append_array(safe)
    return result

func begin(renderer_override: String = "", force_headless: bool = false) -> bool:
    if status == "warming" or status == "completed":
        return false
    if DisplayServer.get_name() == "headless" and not force_headless:
        status = "skipped_headless"
        return false
    renderer = Registry.renderer_family(renderer_override)
    warmed_paths = planned_shader_paths(renderer)
    _build_viewport(warmed_paths)
    _frames_remaining = 6
    status = "warming"
    set_process(true)
    return true

func reset_for_test() -> void:
    if _viewport != null:
        _viewport.queue_free()
        _viewport = null
    status = "idle"
    renderer = ""
    warmed_paths.clear()
    _frames_remaining = 0
    set_process(false)

func debug_snapshot() -> Dictionary:
    return {
        "status": status,
        "renderer": renderer,
        "paths": warmed_paths.duplicate(),
        "frames_remaining": _frames_remaining,
    }

func _build_viewport(paths: Array[String]) -> void:
    if _viewport != null:
        _viewport.queue_free()
    _viewport = SubViewport.new()
    _viewport.name = "ShaderWarmupViewport"
    _viewport.size = Vector2i(96, 96)
    _viewport.own_world_3d = true
    _viewport.transparent_bg = false
    _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    add_child(_viewport)

    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.025, 0.03, 0.035)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.75, 0.78, 0.82)
    environment.ambient_light_energy = 1.0
    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    _viewport.add_child(world_environment)

    var camera := Camera3D.new()
    camera.position = Vector3(0.0, 1.6, 5.8)
    camera.fov = 58.0
    camera.current = true
    _viewport.add_child(camera)
    camera.look_at(Vector3(0.0, 0.3, 0.0), Vector3.UP)

    var key := DirectionalLight3D.new()
    key.rotation_degrees = Vector3(-45.0, -28.0, 0.0)
    key.light_energy = 1.5
    key.shadow_enabled = false
    _viewport.add_child(key)

    var columns := 3
    for index in range(paths.size()):
        var shader := load(paths[index]) as Shader
        if shader == null:
            push_error("ShaderWarmup: failed to load %s" % paths[index])
            continue
        var material := ShaderMaterial.new()
        material.shader = shader
        material.set_shader_parameter("visibility_distance", 3200.0)
        var mesh := BoxMesh.new()
        mesh.size = Vector3(0.72, 0.72, 0.72)
        mesh.material = material
        var instance := MeshInstance3D.new()
        instance.name = "Warmup_%02d" % index
        instance.mesh = mesh
        var row := index / columns
        var column := index % columns
        instance.position = Vector3((float(column) - 1.0) * 1.0, 0.25 - float(row) * 0.9, -float(row) * 0.15)
        _viewport.add_child(instance)

func _finish() -> void:
    status = "completed"
    set_process(false)
    if _viewport != null:
        _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
        _viewport.queue_free()
        _viewport = null
