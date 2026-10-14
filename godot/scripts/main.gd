extends Node3D

const RoadScript = preload("res://scripts/road_streamer.gd")
const TerrainScript = preload("res://scripts/terrain_streamer.gd")
const VehicleScript = preload("res://scripts/vehicle_controller.gd")
const PlayerScript = preload("res://scripts/player_controller.gd")
const TouchScript = preload("res://scripts/touch_controls.gd")
const SaveScript = preload("res://scripts/save_game.gd")
const VisualScript = preload("res://scripts/world_visuals.gd")
const HUDScript = preload("res://scripts/hud.gd")
const BuildingScript = preload("res://scripts/building_streamer.gd")
const AudioScript = preload("res://scripts/game_audio.gd")
const SAVE_PATH := "user://yardman/save.json"
const SETTINGS_PATH := "user://yardman/settings.json"

var car: CharacterBody3D
var vehicle = VehicleScript.new()
var player
var roads
var terrain
var buildings
var game_audio
var visuals = VisualScript.new()
var touch
var camera: Camera3D
var sun: DirectionalLight3D
var environment: Environment
var hud
var parish_menu: OptionButton
var quality_menu: OptionButton
var current_parish := "St. Mary"
var camera_yaw := 0.0
var camera_pitch := -0.20
var camera_orbit := 0.0
var world_ready := false
var _settle_spawn := true
var _spawn_ready_frames := 0
var _message := ""
var _message_time := 0.0
var _save_clock := 0.0
var day_hour := 9.0
var _car_world := PackedFloat64Array()
var _decoration_records: Dictionary = {}
var _radar_clock := 0.0
var _surface_clock := 0.0
var _preferences_loaded := false
var _app_active := true

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
    roads.tile_removed.connect(func(tile: Vector2i) -> void: _decoration_records.erase(tile))
    add_child(roads)
    terrain = TerrainScript.new()
    terrain.name = "JamaicaTerrainStreamer"
    terrain.data_root = "res://data/terrain"
    terrain.coordinates = roads.coordinates
    terrain.target = car
    terrain.visuals = visuals
    terrain.tile_ready.connect(_decorate_ready_terrain)
    add_child(terrain)
    buildings = BuildingScript.new()
    buildings.name = "JamaicaBuildingStreamer"
    buildings.configure("res://data/buildings", roads.coordinates, terrain)
    buildings.target = car
    add_child(buildings)
    camera = Camera3D.new()
    camera.name = "FollowCamera"
    camera.far = 45000.0
    camera.near = 0.5
    camera.fov = 78.0
    camera.current = true
    add_child(camera)
    _make_hud()
    game_audio = AudioScript.new()
    game_audio.name = "GameAudio"
    add_child(game_audio)
    set_quality("Quality")
    var snapshot: Dictionary = SaveScript.load_file(SAVE_PATH)
    if snapshot.is_empty():
        goto_parish(current_parish)
    else:
        restore_snapshot(snapshot)
    _load_preferences()

func _make_environment() -> void:
    environment = Environment.new()
    var world_env := WorldEnvironment.new()
    world_env.environment = environment
    add_child(world_env)
    sun = DirectionalLight3D.new()
    add_child(sun)
    visuals.configure_environment(environment, sun)
    # Water is compiled from the actual coastline in each streamed terrain tile.

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
    add_child(car)

func _make_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "YardmanHUD"
    add_child(layer)
    touch = TouchScript.new()
    touch.name = "TouchControls"
    layer.add_child(touch)
    hud = HUDScript.new()
    hud.name = "GameHUD"
    hud.configure(roads.manifest.get("parish_anchors", {}).keys(), VisualScript.PROFILES.keys())
    layer.add_child(hud)
    hud.attach_controls(touch)
    parish_menu = hud.parish_menu
    quality_menu = hud.quality_menu
    hud.travel_requested.connect(goto_parish)
    hud.quality_requested.connect(func(quality: String) -> void:
        if quality == "Custom":
            _show_custom_settings()
        else:
            set_quality(quality)
            _save_preferences())
    hud.save_requested.connect(save_game)
    hud.recover_requested.connect(func() -> void: goto_parish(current_parish))
    hud.interaction_requested.connect(toggle_vehicle)
    hud.credits_requested.connect(_show_credits)
    touch.settings_changed.connect(func(_settings: Dictionary) -> void: _save_preferences())

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
    _spawn_ready_frames = 0
    world_ready = false
    _refresh_streamers()
    _select_parish()
    camera.position = car.position + Vector3(0, 4.0, 8.0).rotated(Vector3.UP, car.rotation.y)
    camera_orbit = 0.0
    camera_yaw = car.rotation.y
    touch.clear_input()

func _select_parish() -> void:
    if hud != null:
        hud.select_parish(current_parish)

func set_quality(quality: String, custom: Dictionary = {}) -> void:
    if not VisualScript.PROFILES.has(quality):
        quality = "Balanced"
    visuals.quality = quality
    visuals.custom = custom.duplicate()
    visuals.apply_environment_quality(environment, quality)
    var profile: Dictionary = visuals.settings().duplicate()
    if quality == "Custom":
        profile.merge(custom, true)
    roads.load_radius = clampi(int(profile.road_radius), 1, 3)
    terrain.load_radius = clampi(int(profile.terrain_radius), 1, 2)
    sun.shadow_enabled = bool(profile.shadows)
    get_viewport().scaling_3d_scale = clampf(float(profile.get("resolution", 0.75 if quality == "Performance" else 1.0)), 0.5, 1.25)
    for tile_root in roads._loaded.values():
        visuals.apply_roadside_quality(tile_root)
    roads.surface_visibility_distance = 1800.0 if quality == "Performance" else 2600.0
    buildings.quality = quality
    if quality == "Custom":
        buildings.draw_distance = float(profile.get("building_distance", 800.0))
    _refresh_streamers()
    if hud != null:
        hud.select_quality(quality)

func _decorate_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    # Retain centreline fields, not repeated DEM-clipped polygon vertices.
    var records: Array = []
    var seen: Dictionary = {}
    for segment in segments:
        if not segment is Array or segment.size() < 11:
            continue
        var identifier := "%s:%s:%s:%s:%s:%s" % [str(segment[7]), str(segment[8]), str(segment[0]), str(segment[1]), str(segment[2]), str(segment[3])]
        if seen.has(identifier):
            continue
        seen[identifier] = true
        records.append(segment.slice(0, 11))
    _decoration_records[tile] = records
    if terrain != null and terrain.is_tile_ready(tile):
        visuals.make_roadside(tile_root, records, tile, roads.tile_size, terrain.height_at)

func _decorate_ready_terrain(tile: Vector2i) -> void:
    var tile_root = roads._loaded.get(roads._tile_key(tile.x, tile.y))
    if tile_root != null and _decoration_records.has(tile):
        visuals.make_roadside(tile_root, _decoration_records[tile], tile, roads.tile_size, terrain.height_at)

func _refresh_streamers() -> void:
    var active: Node3D = car if player.in_vehicle else player
    roads.target = active
    terrain.target = active
    buildings.target = active
    roads._refresh_tiles(true)
    terrain._refresh_tiles(true)
    var world: PackedFloat64Array = roads.local_to_world(active.position)
    buildings.update_world(world[0], world[2], true)

func _rebase(x: float, z: float) -> void:
    # A parked car can outlive its collision tile. Preserve its double-precision
    # location rather than repeatedly accumulating large float transform shifts.
    var car_world: PackedFloat64Array = _car_world if not _car_world.is_empty() else roads.local_to_world(car.position)
    var player_world: PackedFloat64Array = roads.local_to_world(player.position)
    var shift: Vector3 = roads.rebase_origin(x, z)
    if terrain != null:
        terrain.rebase_by(shift)
    if buildings != null:
        buildings.rebase_by(shift)
    car.position = roads.world_to_local(car_world[0], car_world[2], car_world[1])
    player.position = roads.world_to_local(player_world[0], player_world[2], player_world[1])
    if camera != null:
        camera.position += shift

func toggle_vehicle() -> void:
    if not world_ready or hud.menu_open or touch.layout_editing:
        return
    var changed: bool = player.try_exit_vehicle() if player.in_vehicle else player.try_enter_vehicle()
    if not changed:
        _notify("Stop beside the car to enter or exit")
        return
    camera_orbit = 0.0
    camera_yaw = car.rotation.y
    touch.driving = player.in_vehicle
    _refresh_streamers()

func _unhandled_key_input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed or event.echo:
        return
    if hud != null and (hud.menu_open or touch.layout_editing):
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
    if ready and _settle_spawn:
        # Tile signals add the deck collider during processing. Allow a physics
        # frame to register it before either actor resumes collision movement.
        _spawn_ready_frames += 1
        if _spawn_ready_frames < 2:
            ready = false
        elif not _settle_actor_spawn(active):
            _notify("The saved location is offshore; recovering to a road")
            goto_parish(current_parish)
            return
        else:
            _settle_spawn = false
            _spawn_ready_frames = 0
    elif _settle_spawn:
        _spawn_ready_frames = 0
    world_ready = ready
    if ready and world[1] < -5.0 and not bool(_spawn_support(world[0], world[2], world[1]).structural):
        goto_parish(current_parish)
        _notify("Recovered to shore")
        return
    if absf(active.position.x) > 6144.0 or absf(active.position.z) > 6144.0:
        _rebase(world[0], world[2])
    var blocked: bool = hud.menu_open or touch.layout_editing or not _app_active
    touch.driving = player.in_vehicle
    var keyboard_forward := Input.get_axis("ui_down", "ui_up")
    var keyboard_turn := Input.get_axis("ui_left", "ui_right")
    keyboard_forward += float(int(Input.is_physical_key_pressed(KEY_W)) - int(Input.is_physical_key_pressed(KEY_S)))
    keyboard_turn += float(int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A)))
    var throttle := clampf(keyboard_forward + touch.throttle(), -1.0, 1.0) if not blocked else 0.0
    var turn := clampf(keyboard_turn + touch.steering(), -1.0, 1.0) if not blocked else 0.0
    var look: Vector2 = touch.consume_look() if not blocked else Vector2.ZERO
    camera_orbit -= look.x * 0.004
    camera_pitch = clampf(camera_pitch - look.y * 0.002, -0.75, 0.20)
    camera_yaw = car.rotation.y + camera_orbit if player.in_vehicle else camera_yaw - look.x * 0.004
    player.movement = (Vector2(keyboard_turn, -keyboard_forward) + touch.movement_vector()).limit_length(1.0) if not blocked else Vector2.ZERO
    player.camera_yaw = camera_yaw
    player.sprinting = not blocked and (Input.is_physical_key_pressed(KEY_SHIFT) or touch.sprint_held())
    player.reduced_motion = bool(touch.settings.reduced_motion)
    vehicle.brake_input = touch.brake() if not blocked else 0.0
    vehicle.handbrake = not blocked and (touch.handbrake_held() or Input.is_physical_key_pressed(KEY_SPACE))
    var car_world: PackedFloat64Array = roads.local_to_world(car.position)
    var car_ready := _collision_ready(car_world[0], car_world[2])
    _surface_clock += delta
    if _surface_clock >= 0.2:
        _surface_clock = 0.0
        var surface: Dictionary = roads.road_surface_at(car_world[0], car_world[2])
        vehicle.on_road = bool(surface.get("found", false)) and str(surface.get("surface", "")) == "paved"
    # A menu pauses actors; streaming continues so changing graphics cannot
    # strand the player. An unloaded parked car keeps its canonical position.
    vehicle.step(delta, throttle, turn, not blocked and (ready and car_ready if player.in_vehicle else car_ready))
    if car_ready:
        _car_world = roads.local_to_world(car.position)
    player.step(delta, ready and not blocked)
    _update_camera(delta)
    _save_clock += delta
    if ready and _save_clock > 30.0:
        save_game()
    _message_time = maxf(0.0, _message_time - delta)
    if not blocked:
        day_hour = fmod(day_hour + delta / 120.0, 24.0)
    visuals.update_daylight(day_hour, environment)
    var can_interact: bool = player.can_exit_vehicle() if player.in_vehicle else player.can_enter_vehicle()
    var speed: float = absf(vehicle.speed_mps) * 3.6 if player.in_vehicle else Vector2(player.velocity.x, player.velocity.z).length() * 3.6
    hud.set_status({"parish": current_parish, "speed_kmh": speed, "driving": player.in_vehicle,
        "ready": ready, "can_interact": can_interact, "message": _message if _message_time > 0.0 else "",
        "heading": camera_yaw, "gear": vehicle.gear_label(), "time_hour": day_hour})
    game_audio.update_state(delta, {"driving": player.in_vehicle, "speed_mps": vehicle.speed_mps,
        "rpm": vehicle.engine_rpm, "on_road": vehicle.on_road, "walk_speed": speed / 3.6,
        "ready": ready, "menu_open": blocked, "throttle": throttle})
    _radar_clock += delta
    if _radar_clock >= 0.5:
        _radar_clock = 0.0
        hud.set_radar_paths(roads.nearby_paths(world[0], world[2]), Vector2(world[0], world[2]), camera_yaw)

func _collision_ready(x: float, z: float) -> bool:
    # Freeze traversal until the footprint's neighboring colliders are resident.
    for dx in [-5.0, 0.0, 5.0]:
        for dz in [-5.0, 0.0, 5.0]:
            if not terrain.is_world_position_ready(x + dx, z + dz):
                return false
            var road_tile: Vector2i = roads.coordinates.tile_for(x + dx, z + dz)
            if roads.has_tile(road_tile) and not roads.is_tile_ready(road_tile):
                return false
    return true

func _settle_actor_spawn(actor: Node3D) -> bool:
    var world: PackedFloat64Array = roads.local_to_world(actor.position)
    var support := _spawn_support(world[0], world[2], world[1])
    var height := float(support.height)
    if not is_finite(height):
        return false
    # Height is canonical metres, not the render origin's local Y coordinate.
    actor.position.y = roads.world_to_local(world[0], world[2], height + 0.35).y
    return true

func _spawn_support(x: float, z: float, saved_elevation: float) -> Dictionary:
    var ground: float = terrain.height_at(x, z)
    var result := {"height": ground, "structural": false}
    if not is_finite(x) or not is_finite(z) or not is_finite(saved_elevation):
        return result
    var local: Vector3 = roads.world_to_local(x, z, saved_elevation)
    var tile: Vector2i = roads.coordinates.tile_for(x, z)
    var nearest := absf(saved_elevation - ground) if is_finite(ground) else INF
    # The surface query index deliberately omits elevations. Query only nearby
    # resident driving-deck triangles instead, retaining the streamed profile
    # and distinguishing a tunnel, bridge and ground at the same horizontal XY.
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var key := "%d:%d" % [tile.x + dx, tile.y + dz]
            var tile_root = roads._loaded.get(key)
            if not tile_root is Node3D:
                continue
            var collider := tile_root.get_node_or_null("RoadStructureDeckCollision/RoadStructureDeckCollisionShape") as CollisionShape3D
            if collider == null or not collider.shape is ConcavePolygonShape3D:
                continue
            var transform: Transform3D = roads.global_transform.affine_inverse() * collider.global_transform
            var faces := (collider.shape as ConcavePolygonShape3D).get_faces()
            for index in range(0, faces.size() - 2, 3):
                var a: Vector3 = transform * faces[index]
                var b: Vector3 = transform * faces[index + 1]
                var c: Vector3 = transform * faces[index + 2]
                var height := _triangle_height(Vector2(local.x, local.z), a, b, c)
                if not is_finite(height):
                    continue
                height = roads.local_to_world(Vector3(local.x, height, local.z))[1]
                var distance := absf(saved_elevation - height)
                # A saved grounded actor is close to its supporting surface.
                # Do not pull somebody on ground up onto a crossing bridge.
                if distance > 2.0 or distance > nearest + 0.00001:
                    continue
                if absf(distance - nearest) < 0.00001 and bool(result.structural) and height >= float(result.height):
                    continue
                nearest = distance
                result = {"height": height, "structural": true}
    return result

static func _triangle_height(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> float:
    var edge_b := Vector2(b.x - a.x, b.z - a.z)
    var edge_c := Vector2(c.x - a.x, c.z - a.z)
    var offset := point - Vector2(a.x, a.z)
    var determinant := edge_b.cross(edge_c)
    if absf(determinant) < 0.000001:
        return NAN
    var weight_b := offset.cross(edge_c) / determinant
    var weight_c := edge_b.cross(offset) / determinant
    if weight_b < -0.00001 or weight_c < -0.00001 or weight_b + weight_c > 1.00001:
        return NAN
    return a.y + weight_b * (b.y - a.y) + weight_c * (c.y - a.y)

func _update_camera(delta: float) -> void:
    var subject: Node3D = car if player.in_vehicle else player
    var pivot := subject.position + Vector3.UP * (1.5 if player.in_vehicle else 1.4)
    var reduced_motion := bool(touch.settings.reduced_motion)
    var desired_fov := (78.0 if reduced_motion else lerpf(78.0, 85.0, clampf(absf(vehicle.speed_mps) / 42.0, 0.0, 1.0))) if player.in_vehicle else 75.0
    camera.fov = lerpf(camera.fov, desired_fov, clampf(delta * 3.0, 0.0, 1.0))
    var distance := 7.8 if player.in_vehicle else 4.6
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
    _spawn_ready_frames = 0
    world_ready = false
    camera.position = (car.position if player.in_vehicle else player.position) + Vector3(0, 4, 8)
    camera_yaw = car.rotation.y if player.in_vehicle else player.rotation.y
    camera_orbit = 0.0
    touch.clear_input()
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
    for setting in [["trees", "Trees per road tile", 40.0, 1800.0, 20.0, 500.0],
            ["road_radius", "Road tile radius", 1.0, 3.0, 1.0, 2.0],
            ["terrain_radius", "Terrain tile radius", 1.0, 2.0, 1.0, 1.0],
            ["building_distance", "Building draw distance (metres)", 256.0, 1800.0, 64.0, 800.0],
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
        _save_preferences()
        dialog.queue_free())
    dialog.canceled.connect(dialog.queue_free)
    dialog.min_size = Vector2i(440, 450)
    add_child(dialog)
    dialog.popup_centered()

func _load_preferences() -> void:
    if FileAccess.file_exists(SETTINGS_PATH):
        var settings = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
        if settings is Dictionary:
            var controls = settings.get("controls", {})
            touch.apply_settings(controls if controls is Dictionary else {})
            var custom = settings.get("custom_quality", {})
            set_quality(str(settings.get("quality", visuals.quality)), custom if custom is Dictionary else {})
            game_audio.set_volume(float(settings.get("audio_volume", 0.6)))
    _preferences_loaded = true

func _save_preferences() -> void:
    if not _preferences_loaded or touch == null:
        return
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SETTINGS_PATH.get_base_dir()))
    var file := FileAccess.open(SETTINGS_PATH + ".tmp", FileAccess.WRITE)
    if file == null:
        _notify("Could not save control settings")
        return
    file.store_string(JSON.stringify({"schema": 1, "controls": touch.get_settings(),
        "quality": visuals.quality, "custom_quality": visuals.custom,
        "audio_volume": game_audio.volume}, "", true, true))
    file.flush()
    file.close()
    if DirAccess.rename_absolute(SETTINGS_PATH + ".tmp", SETTINGS_PATH) != OK:
        _notify("Could not save control settings")

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        _app_active = false
        if game_audio != null:
            game_audio.update_state(0.016, {"ready": false})
        if world_ready:
            save_game()
            _save_preferences()
    elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED:
        _app_active = true
