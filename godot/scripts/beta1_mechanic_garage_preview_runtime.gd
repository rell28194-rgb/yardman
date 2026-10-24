extends Node
class_name YardmanBeta1MechanicGaragePreviewRuntime

# Owner-private recovered Mechanic equipment is useful in the garage UI, not as
# fabricated Jamaica geography. This runtime creates a tiny isolated SubViewport
# only when the existing garage panel is opened. It renders once on open and
# again only when the highlighted installed vehicle changes.
const References = preload("res://scripts/reference_assets.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const AcceptedModel = preload("res://scripts/vehicle_model.gd")
const FleetModel = preload("res://scripts/fleet_vehicle_model.gd")
const PREVIEW_SIZE := Vector2i(384, 216)
const PREVIEW_PANEL_SIZE := Vector2(404.0, 256.0)
const GARAGE_FALLBACK_SIZE := Vector2(410.0, 320.0)
const GARAGE_PREVIEW_GAP := 14.0
const MIN_SCREEN_MARGIN := 12.0
const ASSETS := [
    {"file": "garage_tire_changer.glb", "position": Vector3(-2.65, 0.08, 0.15), "yaw": -0.18},
    {"file": "garage_tire_balancer.glb", "position": Vector3(2.60, 0.08, 0.15), "yaw": 0.20},
    {"file": "garage_grinder.glb", "position": Vector3(0.0, 0.92, -1.72), "yaw": -0.35},
    {"file": "garage_polisher.glb", "position": Vector3(-0.48, 0.92, -1.70), "yaw": 0.22},
    {"file": "garage_screw_extractor.glb", "position": Vector3(0.52, 0.93, -1.72), "yaw": -0.12},
]
const MAX_RECOVERED_PROPS := 5
const POLL_INTERVAL_S := 0.15

var _garage: Node
var _garage_panel: Control
var _preview_panel: PanelContainer
var _texture_rect: TextureRect
var _title_label: Label
var _viewport: SubViewport
var _world: Node3D
var _preview_vehicle_root: Node3D
var _preview_vehicle_id := ""
var _vehicle_loaded := false
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
    _title_label = null
    _preview_vehicle_root = null
    _world = null
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
    var vehicle_changed := false
    if requested_visible and _built:
        vehicle_changed = _sync_vehicle_preview()
    var preview_content_available := _built and (_asset_count > 0 or _vehicle_loaded)
    var can_show := _apply_layout(requested_visible, preview_content_available)
    if can_show and (not _was_visible or vehicle_changed) and _viewport != null:
        _viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
    elif not can_show and _viewport != null:
        _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    _was_visible = can_show

func _apply_layout(garage_visible: bool, preview_available: bool) -> bool:
    if _garage_panel == null or not is_instance_valid(_garage_panel):
        return false
    _garage_panel.set_anchors_preset(Control.PRESET_CENTER)
    var garage_size := _garage_panel.size
    if garage_size.x < 100.0 or garage_size.y < 100.0:
        garage_size = GARAGE_FALLBACK_SIZE
        _garage_panel.size = garage_size
    if not garage_visible:
        _garage_panel.position = -garage_size * 0.5
        if _preview_panel != null and is_instance_valid(_preview_panel):
            _preview_panel.visible = false
        return false
    if not preview_available or _preview_panel == null or not is_instance_valid(_preview_panel):
        _garage_panel.position = -garage_size * 0.5
        if _preview_panel != null and is_instance_valid(_preview_panel):
            _preview_panel.visible = false
        return false

    var viewport_size := get_viewport().get_visible_rect().size
    var layout := paired_layout(viewport_size, garage_size, PREVIEW_PANEL_SIZE)
    _garage_panel.position = layout.garage_position
    _preview_panel.set_anchors_preset(Control.PRESET_CENTER)
    _preview_panel.size = PREVIEW_PANEL_SIZE
    _preview_panel.position = layout.preview_position
    _preview_panel.visible = bool(layout.paired)
    return bool(layout.paired)

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

    _viewport = SubViewport.new()
    _viewport.name = "MechanicGaragePreviewViewport"
    _viewport.size = PREVIEW_SIZE
    _viewport.own_world_3d = true
    _viewport.transparent_bg = false
    _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    _viewport.physics_object_picking = false
    add_child(_viewport)

    _world = Node3D.new()
    _world.name = "MechanicPreviewWorld"
    _viewport.add_child(_world)
    _build_static_bay(_world)
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
        _disable_preview_authority(prop)
        _world.add_child(prop)

    var camera := Camera3D.new()
    camera.name = "PreviewCamera"
    camera.position = Vector3(5.55, 3.35, 6.85)
    camera.fov = 50.0
    camera.current = true
    _world.add_child(camera)
    camera.look_at(Vector3(0.0, 0.92, 0.30), Vector3.UP)

    var key_light := DirectionalLight3D.new()
    key_light.name = "PreviewKey"
    key_light.rotation_degrees = Vector3(-46.0, -34.0, 0.0)
    key_light.light_energy = 1.10
    key_light.shadow_enabled = false
    _world.add_child(key_light)
    var fill := OmniLight3D.new()
    fill.name = "PreviewFill"
    fill.position = Vector3(-2.4, 3.2, 2.8)
    fill.omni_range = 9.0
    fill.light_energy = 1.35
    fill.shadow_enabled = false
    _world.add_child(fill)

    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.055, 0.064, 0.072)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.54, 0.59, 0.64)
    env.ambient_light_energy = 0.62
    var world_env := WorldEnvironment.new()
    world_env.environment = env
    _world.add_child(world_env)

    _preview_panel = PanelContainer.new()
    _preview_panel.name = "MechanicGaragePreview"
    _preview_panel.set_anchors_preset(Control.PRESET_CENTER)
    _preview_panel.size = PREVIEW_PANEL_SIZE
    _preview_panel.position = -PREVIEW_PANEL_SIZE * 0.5
    _preview_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _preview_panel.visible = false
    _garage.add_child(_preview_panel)

    var column := VBoxContainer.new()
    column.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _preview_panel.add_child(column)
    _title_label = Label.new()
    _title_label.text = "WORKSHOP BAY"
    _title_label.add_theme_font_size_override("font_size", 15)
    _title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(_title_label)
    _texture_rect = TextureRect.new()
    _texture_rect.name = "MechanicPreviewImage"
    _texture_rect.custom_minimum_size = Vector2(PREVIEW_SIZE)
    _texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    _texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    _texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _texture_rect.texture = _viewport.get_texture()
    column.add_child(_texture_rect)

    _sync_vehicle_preview()

func _sync_vehicle_preview() -> bool:
    if _garage == null or _world == null:
        return false
    var raw_ids: Variant = _garage.get("_vehicle_ids")
    var ids: Array = raw_ids if raw_ids is Array else []
    var raw_options: Variant = _garage.get("_options")
    var selected := -1
    if raw_options is OptionButton:
        selected = (raw_options as OptionButton).selected
    var fallback := str(_garage.get("_current_id"))
    var vehicle_id := preview_vehicle_id(ids, selected, fallback)
    if vehicle_id == _preview_vehicle_id:
        return false
    _preview_vehicle_id = vehicle_id
    _vehicle_loaded = false
    if _preview_vehicle_root != null and is_instance_valid(_preview_vehicle_root):
        _preview_vehicle_root.free()
    _preview_vehicle_root = null
    if vehicle_id.is_empty() or not Catalog.has(vehicle_id):
        _update_title(vehicle_id, false)
        return true

    var model: Node3D
    if vehicle_id == Catalog.DEFAULT_ID:
        var crown := AcceptedModel.new()
        crown.build()
        if not bool(crown.get("is_reference_model")):
            crown.free()
            _update_title(vehicle_id, false)
            return true
        model = crown
    else:
        var fleet := FleetModel.new()
        fleet.build(Catalog.hero_scene(vehicle_id))
        if not bool(fleet.get_meta("yardman_dedicated_vehicle_mesh", false)) \
                or bool(fleet.get_meta("yardman_hero_asset_missing_or_invalid", false)):
            fleet.free()
            _update_title(vehicle_id, false)
            return true
        model = fleet

    var bounds: AABB = model.get("geometry_bounds")
    var holder := Node3D.new()
    holder.name = "HighlightedVehiclePreview"
    holder.position = Vector3(0.0, 0.10, 0.55)
    holder.rotation_degrees.y = -24.0
    var scale_factor := preview_scale_for(bounds)
    holder.scale = Vector3.ONE * scale_factor
    holder.set_meta("preview_only", true)
    holder.set_meta("vehicle_id", vehicle_id)
    holder.set_meta("collision_authority", false)
    holder.process_mode = Node.PROCESS_MODE_DISABLED
    model.position = Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z)
    _disable_preview_authority(model)
    holder.add_child(model)
    _world.add_child(holder)
    _preview_vehicle_root = holder
    _vehicle_loaded = true
    _update_title(vehicle_id, true)
    return true

func _update_title(vehicle_id: String, available: bool) -> void:
    if _title_label == null:
        return
    if vehicle_id.is_empty():
        _title_label.text = "WORKSHOP BAY"
        return
    var suffix := "" if available else " · PREVIEW UNAVAILABLE"
    _title_label.text = "WORKSHOP BAY · %s%s" % [Catalog.display_name(vehicle_id), suffix]

func _disable_preview_authority(node: Node) -> void:
    node.process_mode = Node.PROCESS_MODE_DISABLED
    if node is CollisionObject3D:
        var collision := node as CollisionObject3D
        collision.collision_layer = 0
        collision.collision_mask = 0
    if node is CollisionShape3D:
        (node as CollisionShape3D).disabled = true
    for child: Node in node.get_children():
        _disable_preview_authority(child)

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
    bench.position = Vector3(0.0, 0.45, -1.70)
    bench.material_override = _flat_material(Color(0.24, 0.22, 0.19), 0.84)
    world.add_child(bench)

static func preview_vehicle_id(ids: Array, selected_index: int, fallback: String) -> String:
    if selected_index >= 0 and selected_index < ids.size():
        return str(ids[selected_index])
    return fallback

static func preview_scale_for(bounds: AABB) -> float:
    var extent := maxf(bounds.size.x, bounds.size.z)
    if not is_finite(extent) or extent <= 0.01:
        return 1.0
    return clampf(4.2 / extent, 0.38, 1.0)

static func paired_layout(viewport_size: Vector2, garage_size: Vector2,
        preview_size: Vector2 = PREVIEW_PANEL_SIZE) -> Dictionary:
    var safe_viewport := Vector2(maxf(viewport_size.x, 0.0), maxf(viewport_size.y, 0.0))
    var safe_garage := Vector2(maxf(garage_size.x, 0.0), maxf(garage_size.y, 0.0))
    var safe_preview := Vector2(maxf(preview_size.x, 0.0), maxf(preview_size.y, 0.0))
    var total_width := safe_preview.x + GARAGE_PREVIEW_GAP + safe_garage.x
    var can_pair := safe_viewport.x >= total_width + MIN_SCREEN_MARGIN * 2.0 \
        and safe_viewport.y >= maxf(safe_preview.y, safe_garage.y) + MIN_SCREEN_MARGIN * 2.0
    if not can_pair:
        return {
            "paired": false,
            "preview_position": Vector2.ZERO,
            "garage_position": -safe_garage * 0.5,
        }
    var start_x := -total_width * 0.5
    return {
        "paired": true,
        "preview_position": Vector2(start_x, -safe_preview.y * 0.5),
        "garage_position": Vector2(start_x + safe_preview.x + GARAGE_PREVIEW_GAP, -safe_garage.y * 0.5),
    }

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
        "vehicle_preview": true,
        "vehicle_selection_mode": "highlight-before-use",
        "vehicle_render_trigger": "selection-change",
        "max_vehicle_models": 1,
        "fleet_source": "/root/VehicleGarage",
        "layout_mode": "responsive-side-by-side",
        "overlap_controls": false,
        "narrow_screen_fallback": "hide-preview-keep-garage",
        "layout_gap_px": GARAGE_PREVIEW_GAP,
        "min_screen_margin_px": MIN_SCREEN_MARGIN,
        "jamaica_world_placement": false,
        "continuous_rendering": false,
        "physics": false,
        "collision": false,
        "navigation": false,
        "source_scale_preserved": true,
        "asset_absent_fallback": true,
    }
