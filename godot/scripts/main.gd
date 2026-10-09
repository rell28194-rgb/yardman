extends Node3D

const RoadScript = preload("res://scripts/road_streamer.gd")
const TerrainScript = preload("res://scripts/terrain_streamer.gd")
const VehicleScript = preload("res://scripts/vehicle_controller.gd")
const PlayerScript = preload("res://scripts/player_controller.gd")
const TouchScript = preload("res://scripts/touch_controls.gd")
const SaveScript = preload("res://scripts/save_game.gd")
const VisualScript = preload("res://scripts/world_visuals.gd")
const SAVE_PATH := "user://yardman/save.json"

var car: CharacterBody3D
var vehicle = VehicleScript.new()
var player
var roads
var terrain
var visuals = VisualScript.new()
var touch
var camera: Camera3D
var sun: DirectionalLight3D
var environment: Environment
var ocean: MeshInstance3D
var hud_label: Label
var status_label: Label
var interact_button: Button
var parish_menu: OptionButton
var quality_menu: OptionButton
var current_parish := "St. Mary"
var camera_yaw := 0.0
var camera_pitch := -0.20
var camera_orbit := 0.0
var world_ready := false
var _settle_spawn := true
var _message := ""
var _message_time := 0.0
var _save_clock := 0.0
var day_hour := 9.0
var _car_world := PackedFloat64Array()

func _ready() -> void:
    _make_environment()
    _make_car()
    vehicle.configure(car)
    player = PlayerScript.new()
    player.name = "Player"
    player.configure(vehicle)
    add_child(player)
    roads = RoadScript.new()
    roads.name = "JamaicaRoadStreamer"
    roads.target = car
    roads.tile_content_ready.connect(_decorate_tile)
    add_child(roads)
    terrain = TerrainScript.new()
    terrain.name = "JamaicaTerrainStreamer"
    terrain.data_root = "res://data/terrain"
    terrain.coordinates = roads.coordinates
    terrain.target = car
    add_child(terrain)
    camera = Camera3D.new()
    camera.name = "FollowCamera"
    camera.far = 45000.0
    camera.near = 0.15
    camera.current = true
    add_child(camera)
    _make_hud()
    set_quality("Balanced")
    var snapshot: Dictionary = SaveScript.load_file(SAVE_PATH)
    if snapshot.is_empty():
        goto_parish(current_parish)
    else:
        restore_snapshot(snapshot)

func _make_environment() -> void:
    environment = Environment.new()
    environment.background_mode = Environment.BG_SKY
    var sky := Sky.new()
    var sky_material := ProceduralSkyMaterial.new()
    sky_material.sky_top_color = Color(0.12, 0.36, 0.63)
    sky_material.sky_horizon_color = Color(0.67, 0.80, 0.86)
    sky_material.ground_horizon_color = Color(0.64, 0.75, 0.78)
    sky_material.ground_bottom_color = Color(0.17, 0.24, 0.20)
    sky.sky_material = sky_material
    environment.sky = sky
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.75, 0.83, 0.91)
    environment.ambient_light_energy = 0.55
    environment.fog_enabled = true
    environment.fog_density = 0.000035
    environment.fog_light_color = Color(0.65, 0.78, 0.83)
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    var world_env := WorldEnvironment.new()
    world_env.environment = environment
    add_child(world_env)
    sun = DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-45, -35, 0)
    sun.light_energy = 1.4
    sun.directional_shadow_max_distance = 160.0
    add_child(sun)
    # Water is a render plane at canonical sea level; it never replaces terrain.
    ocean = MeshInstance3D.new()
    ocean.name = "SeaLevel"
    var plane := PlaneMesh.new()
    plane.size = Vector2(600000.0, 600000.0)
    ocean.mesh = plane
    var water := StandardMaterial3D.new()
    water.albedo_color = Color(0.04, 0.29, 0.39)
    water.metallic = 0.18
    water.roughness = 0.24
    ocean.material_override = water
    ocean.position.y = -0.15
    add_child(ocean)

func _make_car() -> void:
    car = CharacterBody3D.new()
    car.name = "RoadQA"
    car.collision_layer = 2
    car.collision_mask = 1
    var collider := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collider.shape = shape
    collider.position.y = 0.65
    car.add_child(collider)
    visuals.make_vehicle(car)
    add_child(car)

func _make_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "YardmanHUD"
    add_child(layer)
    var root_control := Control.new()
    root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(root_control)
    var panel := Panel.new()
    panel.position = Vector2(16, 16)
    panel.size = Vector2(400, 112)
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.025, 0.045, 0.055, 0.78)
    style.set_corner_radius_all(12)
    panel.add_theme_stylebox_override("panel", style)
    root_control.add_child(panel)
    hud_label = Label.new()
    hud_label.position = Vector2(30, 24)
    hud_label.add_theme_font_size_override("font_size", 24)
    root_control.add_child(hud_label)
    status_label = Label.new()
    status_label.position = Vector2(30, 134)
    status_label.add_theme_font_size_override("font_size", 20)
    status_label.add_theme_color_override("font_shadow_color", Color.BLACK)
    status_label.add_theme_constant_override("shadow_offset_x", 2)
    status_label.add_theme_constant_override("shadow_offset_y", 2)
    root_control.add_child(status_label)
    parish_menu = OptionButton.new()
    parish_menu.position = Vector2(430, 22)
    parish_menu.size = Vector2(224, 54)
    parish_menu.focus_mode = Control.FOCUS_NONE
    for parish in roads.manifest.get("parish_anchors", {}).keys():
        parish_menu.add_item(str(parish))
    parish_menu.item_selected.connect(func(index: int) -> void: goto_parish(parish_menu.get_item_text(index)))
    root_control.add_child(parish_menu)
    quality_menu = OptionButton.new()
    quality_menu.position = Vector2(668, 22)
    quality_menu.size = Vector2(180, 54)
    quality_menu.focus_mode = Control.FOCUS_NONE
    for quality in VisualScript.PROFILES.keys():
        quality_menu.add_item(str(quality))
    quality_menu.item_selected.connect(func(index: int) -> void:
        var quality := quality_menu.get_item_text(index)
        if quality == "Custom":
            _show_custom_settings()
        else:
            set_quality(quality))
    root_control.add_child(quality_menu)
    interact_button = _button("EXIT", Vector2(-184, 22), Vector2(160, 58), 1.0)
    interact_button.pressed.connect(toggle_vehicle)
    root_control.add_child(interact_button)
    var save_button := _button("SAVE", Vector2(-184, 92), Vector2(160, 54), 1.0)
    save_button.pressed.connect(save_game)
    root_control.add_child(save_button)
    var reset_button := _button("RECOVER", Vector2(-184, 158), Vector2(160, 54), 1.0)
    reset_button.pressed.connect(func() -> void: goto_parish(current_parish))
    root_control.add_child(reset_button)
    var credits_button := _button("DATA / CREDITS", Vector2(-214, 224), Vector2(190, 50), 1.0)
    credits_button.pressed.connect(_show_credits)
    root_control.add_child(credits_button)
    touch = TouchScript.new()
    touch.name = "TouchControls"
    root_control.add_child(touch)

func _button(text_value: String, offset: Vector2, dimensions: Vector2, anchor_x: float = 0.0) -> Button:
    var button := Button.new()
    button.text = text_value
    button.anchor_left = anchor_x
    button.anchor_right = anchor_x
    button.offset_left = offset.x
    button.offset_top = offset.y
    button.offset_right = offset.x + dimensions.x
    button.offset_bottom = offset.y + dimensions.y
    button.focus_mode = Control.FOCUS_NONE
    button.add_theme_font_size_override("font_size", 20)
    return button

func goto_parish(parish: String) -> void:
    var anchor: Dictionary = roads.manifest.get("parish_anchors", {}).get(parish, {})
    if anchor.is_empty():
        _notify("No source road anchor for " + parish)
        return
    current_parish = parish
    var position_world: Array = anchor.get("road_position", [anchor.x, 0.0, anchor.z])
    _rebase(float(position_world[0]), float(position_world[2]))
    car.position = roads.world_to_local(float(position_world[0]), float(position_world[2]), float(position_world[1]) + 0.45)
    car.rotation = Vector3(0.0, float(anchor.get("heading", 0.0)), 0.0)
    _car_world = PackedFloat64Array([float(position_world[0]), float(position_world[1]) + 0.45, float(position_world[2])])
    vehicle.reset_motion()
    player._set_occupied(true)
    player.position = car.position
    _settle_spawn = true
    world_ready = false
    _refresh_streamers()
    _select_parish()
    camera.position = car.position + Vector3(0, 4.0, 8.0).rotated(Vector3.UP, car.rotation.y)
    camera_orbit = 0.0

func _select_parish() -> void:
    if parish_menu == null:
        return
    for index in range(parish_menu.item_count):
        if parish_menu.get_item_text(index) == current_parish:
            parish_menu.select(index)
            return

func set_quality(quality: String, custom: Dictionary = {}) -> void:
    if not VisualScript.PROFILES.has(quality):
        quality = "Balanced"
    visuals.quality = quality
    visuals.custom = custom.duplicate()
    var profile: Dictionary = visuals.settings().duplicate()
    if quality == "Custom":
        profile.merge(custom, true)
    roads.load_radius = clampi(int(profile.road_radius), 1, 3)
    terrain.load_radius = clampi(int(profile.terrain_radius), 1, 2)
    sun.shadow_enabled = bool(profile.shadows)
    get_viewport().scaling_3d_scale = clampf(float(profile.get("resolution", 0.75 if quality == "Performance" else 1.0)), 0.5, 1.25)
    for tile_root in roads._loaded.values():
        var vegetation := tile_root.get_node_or_null("RoadsideProxy") as MultiMeshInstance3D
        if vegetation != null:
            vegetation.multimesh.visible_instance_count = mini(int(profile.trees), vegetation.multimesh.instance_count)
    _refresh_streamers()
    if quality_menu != null:
        for index in range(quality_menu.item_count):
            if quality_menu.get_item_text(index) == quality:
                quality_menu.select(index)

func _decorate_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    visuals.make_roadside(tile_root, segments, tile, roads.tile_size)

func _refresh_streamers() -> void:
    var active: Node3D = car if player.in_vehicle else player
    roads.target = active
    terrain.target = active
    roads._refresh_tiles(true)
    terrain._refresh_tiles(true)

func _rebase(x: float, z: float) -> void:
    # A parked car can outlive its collision tile. Preserve its double-precision
    # location rather than repeatedly accumulating large float transform shifts.
    var car_world: PackedFloat64Array = _car_world if not _car_world.is_empty() else roads.local_to_world(car.position)
    var player_world: PackedFloat64Array = roads.local_to_world(player.position)
    var shift: Vector3 = roads.rebase_origin(x, z)
    if terrain != null:
        terrain.rebase_by(shift)
    car.position = roads.world_to_local(car_world[0], car_world[2], car_world[1])
    player.position = roads.world_to_local(player_world[0], player_world[2], player_world[1])
    if camera != null:
        camera.position += shift

func toggle_vehicle() -> void:
    if not world_ready:
        return
    var changed: bool = player.try_exit_vehicle() if player.in_vehicle else player.try_enter_vehicle()
    if not changed:
        _notify("Stop beside the car to enter or exit")
        return
    camera_orbit = 0.0
    _refresh_streamers()

func _unhandled_key_input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed or event.echo:
        return
    if event.physical_keycode == KEY_E:
        toggle_vehicle()
    elif event.physical_keycode == KEY_F5:
        save_game()
    elif event.physical_keycode == KEY_R:
        goto_parish(current_parish)

func _physics_process(delta: float) -> void:
    if terrain == null or touch == null:
        return
    var active: Node3D = car if player.in_vehicle else player
    var world: PackedFloat64Array = roads.local_to_world(active.position)
    var ready := _collision_ready(world[0], world[2])
    var road_tile: Vector2i = roads.coordinates.tile_for(world[0], world[2])
    ready = ready and (not roads.has_tile(road_tile) or roads.is_tile_ready(road_tile))
    world_ready = ready
    if ready and _settle_spawn:
        var height: float = terrain.height_at(world[0], world[2])
        active.position.y = height + 0.35
        _settle_spawn = false
    if absf(active.position.x) > 6144.0 or absf(active.position.z) > 6144.0:
        _rebase(world[0], world[2])
    var throttle: float = Input.get_axis("ui_down", "ui_up") + touch.throttle()
    var turn: float = Input.get_axis("ui_left", "ui_right") + touch.steering()
    throttle += float(int(Input.is_physical_key_pressed(KEY_W)) - int(Input.is_physical_key_pressed(KEY_S)))
    turn += float(int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A)))
    throttle = clampf(throttle, -1.0, 1.0)
    turn = clampf(turn, -1.0, 1.0)
    var look: Vector2 = touch.consume_look()
    camera_orbit -= look.x * 0.004
    camera_pitch = clampf(camera_pitch - look.y * 0.002, -0.75, 0.15)
    camera_yaw = car.rotation.y + camera_orbit if player.in_vehicle else camera_yaw - look.x * 0.004
    player.movement = Vector2(turn, -throttle)
    player.camera_yaw = camera_yaw
    player.sprinting = Input.is_physical_key_pressed(KEY_SHIFT)
    var car_world: PackedFloat64Array = roads.local_to_world(car.position)
    var car_ready := _collision_ready(car_world[0], car_world[2])
    # On foot, readiness belongs to the player. Never simulate a parked car
    # against an unloaded distant collision surface.
    vehicle.step(delta, throttle, turn, ready and car_ready if player.in_vehicle else car_ready)
    if car_ready:
        _car_world = roads.local_to_world(car.position)
    player.step(delta, ready)
    touch.driving = player.in_vehicle
    _update_camera(delta)
    _save_clock += delta
    if ready and _save_clock > 30.0:
        save_game()
    _message_time = maxf(0.0, _message_time - delta)
    day_hour = fmod(day_hour + delta / 120.0, 24.0)
    sun.rotation_degrees.x = 90.0 - day_hour * 15.0
    sun.light_energy = clampf(sin((day_hour - 6.0) * PI / 12.0), 0.08, 1.0) * 1.4
    hud_label.text = "YARDMAN\n%s • %s   %.0f km/h\nElevation %.0f m  •  %.0f FPS" % [current_parish,
        "DRIVE" if player.in_vehicle else "WALK", absf(vehicle.speed_mps) * 3.6 if player.in_vehicle else player.velocity.length() * 3.6,
        world[1], Engine.get_frames_per_second()]
    status_label.text = "Loading local terrain and roads…" if not ready else (_message if _message_time > 0.0 else "Drag to look • E: enter/exit • F5: save")
    interact_button.text = "EXIT" if player.in_vehicle else "ENTER"

func _collision_ready(x: float, z: float) -> bool:
    # Freeze traversal until the footprint's neighboring colliders are resident.
    for dx in [-5.0, 0.0, 5.0]:
        for dz in [-5.0, 0.0, 5.0]:
            if not terrain.is_world_position_ready(x + dx, z + dz):
                return false
    return true

func _update_camera(delta: float) -> void:
    var subject: Node3D = car if player.in_vehicle else player
    var pivot := subject.position + Vector3.UP * (1.5 if player.in_vehicle else 1.4)
    var distance := 8.0 if player.in_vehicle else 5.0
    var offset := Vector3(0.0, -sin(camera_pitch) * distance + 1.4, cos(camera_pitch) * distance).rotated(Vector3.UP, camera_yaw)
    var desired := pivot + offset
    var query := PhysicsRayQueryParameters3D.create(pivot, desired, 1)
    query.exclude = [car.get_rid(), player.get_rid()]
    var hit := get_world_3d().direct_space_state.intersect_ray(query)
    if not hit.is_empty():
        desired = hit.position + hit.normal * 0.25
    camera.position = camera.position.lerp(desired, clampf(delta * 8.0, 0.0, 1.0))
    if camera.position.distance_squared_to(pivot) > 0.01:
        camera.look_at(pivot, Vector3.UP)

func _actor_snapshot(actor: Node3D) -> Dictionary:
    var world: PackedFloat64Array = _car_world if actor == car and not _car_world.is_empty() else roads.local_to_world(actor.position)
    var projected: PackedFloat64Array = roads.coordinates.world_to_projected(world[0], world[2], world[1])
    return {"easting": projected[0], "northing": projected[1], "elevation": projected[2], "heading": actor.rotation.y}

func get_snapshot() -> Dictionary:
    return {"schema": 1, "crs": "EPSG:3448", "car": _actor_snapshot(car), "player": _actor_snapshot(player),
        "in_vehicle": player.in_vehicle, "parish": current_parish, "quality": visuals.quality,
        "custom_quality": visuals.custom.duplicate(), "odometer_m": vehicle.odometer_m, "day_hour": day_hour}

func restore_snapshot(snapshot: Dictionary) -> void:
    if not SaveScript.valid(snapshot):
        goto_parish(current_parish)
        return
    current_parish = str(snapshot.get("parish", current_parish))
    var car_world: PackedFloat64Array = roads.coordinates.projected_to_world(float(snapshot.car.easting), float(snapshot.car.northing), float(snapshot.car.elevation))
    var player_world: PackedFloat64Array = roads.coordinates.projected_to_world(float(snapshot.player.easting), float(snapshot.player.northing), float(snapshot.player.elevation))
    var active := car_world if bool(snapshot.get("in_vehicle", true)) else player_world
    _rebase(active[0], active[2])
    car.position = roads.world_to_local(car_world[0], car_world[2], car_world[1])
    _car_world = car_world.duplicate()
    car.rotation.y = float(snapshot.car.get("heading", 0.0))
    player.position = roads.world_to_local(player_world[0], player_world[2], player_world[1])
    player.rotation.y = float(snapshot.player.get("heading", 0.0))
    player._set_occupied(bool(snapshot.get("in_vehicle", true)))
    vehicle.reset_motion()
    vehicle.odometer_m = float(snapshot.get("odometer_m", 0.0))
    day_hour = float(snapshot.get("day_hour", 9.0))
    var custom = snapshot.get("custom_quality", {})
    set_quality(str(snapshot.get("quality", "Balanced")), custom if custom is Dictionary else {})
    _select_parish()
    _settle_spawn = true
    world_ready = false
    camera.position = (car.position if player.in_vehicle else player.position) + Vector3(0, 4, 8)
    _refresh_streamers()

func save_game() -> void:
    if not world_ready:
        _notify("Save waits for the local terrain to finish loading")
        return
    var error: Error = SaveScript.save_file(SAVE_PATH, get_snapshot())
    _save_clock = 0.0
    _notify("Saved" if error == OK else "Save failed: " + error_string(error))

func _notify(message: String) -> void:
    _message = message
    _message_time = 4.0

func _show_credits() -> void:
    var dialog := AcceptDialog.new()
    dialog.title = "Yardman • World data"
    dialog.dialog_text = "Original game code and procedural art: Yardman.\n\n" + str(roads.manifest.get("attribution", "")) + "\nThe road database is available under ODbL.\n\n" + str(terrain.manifest.get("attribution", "")) + "\n\nTerrain is a resampled Copernicus DSM, not surveyed bare earth. Road widths without source measurements and vegetation proxies are inferred. Bridge/tunnel deck elevations remain unfinished.\n\nKeyboard: WASD/arrows, E enter/exit, Shift sprint, F5 save, R recover. Touch supports simultaneous steering and throttle."
    dialog.min_size = Vector2i(740, 440)
    dialog.confirmed.connect(dialog.queue_free)
    add_child(dialog)
    dialog.popup_centered()

func _show_custom_settings() -> void:
    var dialog := AcceptDialog.new()
    dialog.title = "Custom graphics"
    dialog.ok_button_text = "Apply"
    var rows := VBoxContainer.new()
    dialog.add_child(rows)
    var inputs: Dictionary = {}
    var profile: Dictionary = visuals.settings()
    for setting in [["trees", "Trees per road tile", 40.0, 400.0, 10.0, 160.0],
            ["road_radius", "Road tile radius", 1.0, 3.0, 1.0, 2.0],
            ["terrain_radius", "Terrain tile radius", 1.0, 2.0, 1.0, 1.0],
            ["resolution", "3D resolution scale", 0.5, 1.25, 0.05, 1.0]]:
        var label := Label.new()
        label.text = str(setting[1])
        rows.add_child(label)
        var number := SpinBox.new()
        number.min_value = float(setting[2])
        number.max_value = float(setting[3])
        number.step = float(setting[4])
        number.value = float(profile.get(setting[0], setting[5]))
        rows.add_child(number)
        inputs[setting[0]] = number
    var shadows := CheckBox.new()
    shadows.text = "Sun shadows"
    shadows.button_pressed = bool(profile.get("shadows", true))
    rows.add_child(shadows)
    dialog.confirmed.connect(func() -> void:
        var custom := {"shadows": shadows.button_pressed}
        for key in inputs:
            custom[key] = inputs[key].value
        set_quality("Custom", custom)
        dialog.queue_free())
    dialog.canceled.connect(dialog.queue_free)
    dialog.min_size = Vector2i(440, 450)
    add_child(dialog)
    dialog.popup_centered()

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_PAUSED and world_ready:
        save_game()
