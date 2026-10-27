extends "res://scripts/main.gd"

# Godot 4.7 has no bool(...) constructor. Keep the owner-build runtime intact
# and override only methods that execute those invalid casts.

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
    sun.shadow_enabled = profile.get("shadows", true) == true
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

func _physics_process(delta: float) -> void:
    if terrain == null or touch == null:
        return
    var active: Node3D = car if player.in_vehicle else player
    var world: PackedFloat64Array = roads.local_to_world(active.position)
    var ready := _collision_ready(world[0], world[2])
    if ready and _settle_spawn:
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
    if ready and world[1] < -5.0 and _spawn_support(world[0], world[2], world[1]).get("structural", false) != true:
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
    player.reduced_motion = touch.settings.reduced_motion == true
    vehicle.brake_input = touch.brake() if not blocked else 0.0
    vehicle.handbrake = not blocked and (touch.handbrake_held() or Input.is_physical_key_pressed(KEY_SPACE))
    var car_world: PackedFloat64Array = roads.local_to_world(car.position)
    var car_ready := _collision_ready(car_world[0], car_world[2])
    _surface_clock += delta
    if _surface_clock >= 0.2:
        _surface_clock = 0.0
        var surface: Dictionary = roads.road_surface_at(car_world[0], car_world[2])
        vehicle.on_road = surface.get("found", false) == true and str(surface.get("surface", "")) == "paved"
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

func _spawn_support(x: float, z: float, saved_elevation: float) -> Dictionary:
    var ground: float = terrain.height_at(x, z)
    var result := {"height": ground, "structural": false}
    if not is_finite(x) or not is_finite(z) or not is_finite(saved_elevation):
        return result
    var local: Vector3 = roads.world_to_local(x, z, saved_elevation)
    var tile: Vector2i = roads.coordinates.tile_for(x, z)
    var nearest := absf(saved_elevation - ground) if is_finite(ground) else INF
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
                if distance > 2.0 or distance > nearest + 0.00001:
                    continue
                if absf(distance - nearest) < 0.00001 and result.get("structural", false) == true and height >= float(result.height):
                    continue
                nearest = distance
                result = {"height": height, "structural": true}
    return result

func _update_camera(delta: float) -> void:
    var subject: Node3D = car if player.in_vehicle else player
    var pivot := subject.position + Vector3.UP * (1.5 if player.in_vehicle else 1.4)
    var reduced_motion: bool = touch.settings.reduced_motion == true
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

func restore_snapshot(snapshot: Dictionary) -> void:
    if not SaveScript.valid(snapshot):
        goto_parish(current_parish)
        return
    current_parish = str(snapshot.get("parish", current_parish))
    var car_world: PackedFloat64Array = roads.coordinates.projected_to_world(float(snapshot.car.easting), float(snapshot.car.northing), float(snapshot.car.elevation))
    var player_world: PackedFloat64Array = roads.coordinates.projected_to_world(float(snapshot.player.easting), float(snapshot.player.northing), float(snapshot.player.elevation))
    var active := car_world if snapshot.get("in_vehicle", true) == true else player_world
    _rebase(active[0], active[2])
    car.position = roads.world_to_local(car_world[0], car_world[2], car_world[1])
    _car_world = car_world.duplicate()
    car.rotation.y = float(snapshot.car.get("heading", 0.0))
    player.position = roads.world_to_local(player_world[0], player_world[2], player_world[1])
    player.rotation.y = float(snapshot.player.get("heading", 0.0))
    player._set_occupied(snapshot.get("in_vehicle", true) == true)
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
    shadows.button_pressed = profile.get("shadows", true) == true
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
