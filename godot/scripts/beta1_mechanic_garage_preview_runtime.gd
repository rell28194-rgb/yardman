extends Node
class_name YardmanBeta1MechanicGaragePreviewRuntime

# Owner-private recovered Mechanic equipment is useful in the garage UI, not as
# fabricated Jamaica geography. This runtime creates a tiny isolated SubViewport
# only when the existing garage panel is opened. The bay is static and renders
# once per open; it has no physics, navigation or world-streaming authority.
const References = preload("res://scripts/reference_assets.gd")
const PREVIEW_SIZE := Vector2i(384, 216)
const PREVIEW_PANEL_SIZE := Vector2(404.0, 256.0)
const PREVIEW_PANEL_OFFSET := Vector2(-830.0, 72.0)
const ASSETS := [
    {"file": "garage_tire_changer.glb", "position": Vector3(-1.35, 0.08, 0.10), "yaw": -0.18},
    {"file": "garage_tire_balancer.glb", "position": Vector3(1.30, 0.08, 0.10), "yaw": 0.20},
    {"file": "garage_grinder.glb", "position": Vector3(0.0, 0.92, -1.45), "yaw": -0.35},
    {"file": "garage_polisher.glb", "position": Vector3(-0.42, 0.92, -1.42), "yaw": 0.22},
    {"file": "garage_screw_extractor.glb", "position": Vector3(0.46, 0.93, -1.46), "yaw": -0.12},
]
const MAX_RECOVERED_PROPS := 5
const POLL_INTERVAL_S := 0.15

var _garage: Node
var _garage_panel: Control
var _preview_panel: PanelContainer
var _texture_rect: TextureRect
var _viewport: SubViewport
var _built := false
var _asset_count := 0
var _clock := 0.0
var _was_visible := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)
    call_deferred("_sync")

func _process(delta: float) -> void:
    _clock += maxf(delta, 0.0)
    if _clock < POLL_INTERVAL_S:
        return
    _clock = 0.0
    _sync()

func _exit_tree() -> void:
    if _preview_panel != null and is_instance_valid(_preview_panel):
        _preview_panel.queue_free()
    _preview_panel = null
    _texture_rect = null
    _garage = null
    _garage_panel = null

func _sync() -> void:
    if _garage == null or not is_instance_valid(_garage):
        _garage = get_node_or_null("/root/VehicleGarage")
        _garage_panel = null
    if _garage == null:
        return
    if _garage_panel == null or not is_instance_valid(_garage_panel):
        var raw_panel: Variant = _garage.get("_panel")
        if raw_panel is Control:
            _garage_panel = raw_panel as Control
    if _garage_panel == null:
        return
    var requested_visible := _garage_panel.visible
    if requested_visible and not _built:
        _build_preview()
    var can_show := requested_visible and _built and _asset_count > 0
    if _preview_panel != null and is_instance_valid(_preview_panel):
        _preview_panel.visible = can_show
    if can_show and not _was_visible and _viewport != null:
        # Static preview: one frame on open rather than a permanently running
        # second 3D renderer on Android.
        _viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
    elif not can_show and _viewport != null:
        _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    _was_visible = can_show

func _build_preview() -> void:
    if _built:
        return
    _built = true
    var loaded: Array[Dictionary] = []
    for record: Dictionary in ASSETS:
        if loaded.size() >= MAX_RECOVERED_PROPS:
            break
        var packed := References.scene(str(record.file))
        if packed != null:
            loaded.append({"record": record, "scene": packed})
    _asset_count = loaded.size()
    if _asset_count == 0:
        return

    _viewport = SubViewport.new()
    _viewport.name = "MechanicGaragePreviewViewport"
    _viewport.size = PREVIEW_SIZE
    _viewport.own_world_3d = true
    _viewport.transparent_bg = false
    _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    _viewport.physics_object_picking = false
    add_child(_viewport)

    var world := Node3D.new()
    world.name = "MechanicPreviewWorld"
    _viewport.add_child(world)
    _build_static_bay(world)
    for item: Dictionary in loaded:
        var scene: PackedScene = item.scene
        var record: Dictionary = item.record
        var prop := scene.instantiate() as Node3D
        if prop == null:
            continue
        prop.name = str(record.file).get_basename().to_pascal_case()
        prop.position = record.position
        prop.rotation.y = float(record.yaw)
        prop.set_meta("preview_only", true)
        prop.set_meta("collision_authority", false)
        world.add_child(prop)

    var camera := Camera3D.new()
    camera.name = "PreviewCamera"
    camera.position = Vector3(5.55, 3.65, 6.65)
    camera.fov = 51.0
    camera.current = true
    world.add_child(camera)
    camera.look_at(Vector3(0.0, 1.05, -0.10), Vector3.UP)

    var key_light := DirectionalLight3D.new()
    key_light.name = "PreviewKey"
    key_light.rotation_degrees = Vector3(-46.0, -34.0, 0.0)
    key_light.light_energy = 1.10
    key_light.shadow_enabled = false
    world.add_child(key_light)
    var fill := OmniLight3D.new()
    fill.name = "PreviewFill"
    fill.position = Vector3(-2.4, 3.2, 2.8)
    fill.omni_range = 9.0
    fill.light_energy = 1.35
    fill.shadow_enabled = false
    world.add_child(fill)

    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.055, 0.064, 0.072)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.54, 0.59, 0.64)
    env.ambient_light_energy = 0.62
    var world_env := WorldEnvironment.new()
    world_env.environment = env
    world.add_child(world_env)

    _preview_panel = PanelContainer.new()
    _preview_panel.name = "MechanicGaragePreview"
    _preview_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    _preview_panel.position = PREVIEW_PANEL_OFFSET
    _preview_panel.size = PREVIEW_PANEL_SIZE
    _preview_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _preview_panel.visible = false
    _garage.add_child(_preview_panel)

    var column := VBoxContainer.new()
    column.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _preview_panel.add_child(column)
    var title := Label.new()
    title.text = "WORKSHOP BAY"
    title.add_theme_font_size_override("font_size", 15)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(title)
    _texture_rect = TextureRect.new()
    _texture_rect.name = "MechanicPreviewImage"
    _texture_rect.custom_minimum_size = Vector2(PREVIEW_SIZE)
    _texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    _texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    _texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _texture_rect.texture = _viewport.get_texture()
    column.add_child(_texture_rect)

func _build_static_bay(world: Node3D) -> void:
    var floor := MeshInstance3D.new()
    floor.name = "PreviewFloor"
    var floor_mesh := BoxMesh.new()
    floor_mesh.size = Vector3(7.2, 0.12, 5.0)
    floor.mesh = floor_mesh
    floor.position = Vector3(0.0, 0.0, 0.0)
    floor.material_override = _flat_material(Color(0.18, 0.19, 0.20), 0.82)
    world.add_child(floor)

    var back := MeshInstance3D.new()
    back.name = "PreviewBackWall"
    var back_mesh := BoxMesh.new()
    back_mesh.size = Vector3(7.2, 3.1, 0.10)
    back.mesh = back_mesh
    back.position = Vector3(0.0, 1.50, -2.45)
    back.material_override = _flat_material(Color(0.13, 0.145, 0.155), 0.90)
    world.add_child(back)

    var bench := MeshInstance3D.new()
    bench.name = "PreviewBench"
    var bench_mesh := BoxMesh.new()
    bench_mesh.size = Vector3(1.45, 0.78, 0.62)
    bench.mesh = bench_mesh
    bench.position = Vector3(0.0, 0.45, -1.45)
    bench.material_override = _flat_material(Color(0.24, 0.22, 0.19), 0.84)
    world.add_child(bench)

static func _flat_material(color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    material.metallic = 0.0
    return material

static func preview_contract() -> Dictionary:
    return {
        "files": [
            "garage_tire_changer.glb",
            "garage_tire_balancer.glb",
            "garage_grinder.glb",
            "garage_polisher.glb",
            "garage_screw_extractor.glb",
        ],
        "viewport": PREVIEW_SIZE,
        "max_recovered_props": MAX_RECOVERED_PROPS,
        "lazy_build": true,
        "render_mode": "one-shot-on-garage-open",
        "garage_surface": "/root/VehicleGarage",
        "jamaica_world_placement": false,
        "continuous_rendering": false,
        "physics": false,
        "collision": false,
        "navigation": false,
        "source_scale_preserved": true,
        "asset_absent_fallback": true,
    }
