extends "res://scripts/main.gd"

# Godot 4.7 has no bool(...) constructor. Keep the owner-build main runtime
# intact and override only live methods that still used those invalid casts.

func set_quality(value: String) -> void:
    visuals.set_quality(value)
    touch.set_quality(value)
    hud.set_quality(value)
    world.set_quality(value)
    vehicle.set_quality(value)
    var profile := visuals.profile()
    streamer.set_quality(float(profile.view_distance), int(profile.max_tiles), profile.tier)
    sky.apply_quality(profile.tier)
    sound_manager.set_quality(profile.tier)
    sun.shadow_enabled = profile.shadows == true
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)

func _physics_process(delta: float) -> void:
    _handle_origin_rebase()
    var ready := world_ready and _app_active
    var keyboard_forward := Input.get_axis("ui_down", "ui_up")
    var keyboard_turn := Input.get_axis("ui_left", "ui_right")
    if player.in_vehicle:
        vehicle.input_forward = touch.throttle + keyboard_forward
        vehicle.input_steer = touch.steering + keyboard_turn
        vehicle.input_brake = maxf(touch.brake, 1.0 if Input.is_action_pressed("ui_accept") else 0.0)
    else:
        vehicle.input_forward = 0.0
        vehicle.input_steer = 0.0
        vehicle.input_brake = 0.0
    var input_router := get_node_or_null("/root/InputRouter")
    if input_router != null:
        input_router.set_touch_active(touch.uses_touch_exclusively())
        vehicle.input_forward = input_router.throttle_value(vehicle.input_forward)
        vehicle.input_steer = input_router.steer_value(vehicle.input_steer)
        vehicle.input_brake = input_router.brake_value(vehicle.input_brake)
        if input_router.consume_interact_action():
            toggle_vehicle()
        if input_router.consume_pause_action():
            _app_active = not _app_active
            if not _app_active:
                vehicle.freeze_motion()
            else:
                _show_message("Resume")
    player.movement = (Vector2(keyboard_turn, -keyboard_forward) + touch.movement_vector()).limit_length(1.0)
    player.camera_yaw = camera_yaw
    _spawn_check_clock += delta
    if _spawn_check_clock >= SPAWN_SUPPORT_INTERVAL:
        _spawn_check_clock = 0.0
        var active_for_support := player if not player.in_vehicle else vehicle.body
        _spawn_support = _spawn_support_for(active_for_support.global_position)
        if not _spawn_support.get("valid", false) \
                and _spawn_support.get("structural", false) != true \
                and (_spawn_support.get("offshore", false) or not player.in_vehicle):
            var safe_position := nav.project_to_road(active_for_support.global_position)
            if safe_position.distance_to(active_for_support.global_position) >= 6.0:
                active_for_support.global_position = safe_position
                if player.in_vehicle:
                    vehicle.freeze_motion()
                else:
                    player.velocity = Vector3.ZERO
                _show_message(str(_spawn_support.get("message", "Returned to mapped ground."))
                    + " Returned to the nearest routable road.")
    player.reduced_motion = touch.settings.reduced_motion == true
    player.step(delta, ready)
    _update_camera(delta)
    tile_budget.set_metrics(fps_monitor.fps(), get_process_delta_time() * 1000.0)
    var active_pos := player.global_position if not player.in_vehicle else vehicle.body.global_position
    var speed := vehicle.speed_mps if player.in_vehicle else Vector2(player.velocity.x, player.velocity.z).length()
    var input_strength := touch.movement_vector().length() if not player.in_vehicle else maxf(absf(vehicle.input_forward), absf(vehicle.input_steer))
    streamer.set_motion(speed, input_strength)
    streamer.set_focus(active_pos)
    building_streamer.set_motion(speed, input_strength)
    building_streamer.set_focus(active_pos)
    if world_ready and world.roads != null and player.in_vehicle:
        var local := vehicle.body.global_position - streamer.world_offset
        var surface := world.roads.surface_at(Vector2(local.x, local.z))
        vehicle.on_road = surface.get("found", false) == true
        vehicle.road_friction = float(surface.get("friction", 1.0))
    vehicle.step(delta, ready)
    _update_contract_progress(delta)
    _publish_optional_content_context(active_pos)
    visuals.update_environment(day_hour, current_parish)
    sky.update(day_hour)
    lights.update(active_pos, camera.global_position, sun_lightness())
    sound_manager.update(delta, vehicle, current_parish, ready, player.in_vehicle, active_pos)
    current_parish = lookup.query_local(active_pos, streamer.world_offset, current_parish)
    hud.set_status({
        "parish": current_parish,
        "speed": vehicle.speed_mps,
        "driving": player.in_vehicle,
        "ready": world_ready,
        "can_interact": player.can_exit_vehicle() if player.in_vehicle else player.can_enter_vehicle(),
        "message": _message if _message_time > 0.0 else "",
        "heading": lookup.heading_degrees(camera_yaw),
        "gear": vehicle.gear_label(),
        "time": day_time_label(),
    })
    if _message_time > 0.0:
        _message_time -= delta
    if world_ready and active_pos.y < -6.0:
        active_pos.y = 0.0
        if player.in_vehicle:
            vehicle.body.global_position = active_pos
            vehicle.freeze_motion()
        else:
            player.global_position = active_pos
            player.velocity = Vector3.ZERO

func _spawn_support(position: Vector3) -> Dictionary:
    var local := position - streamer.world_offset
    var result := world.spawn_support_for(Vector2(local.x, local.z))
    result["position"] = position
    if result.get("structural", false) != true:
        var land := world.land_elevation(Vector2(local.x, local.z))
        var offshore_depth := land - float(result.get("minimum_ground_y", land))
        result["offshore"] = offshore_depth > 1.5
        if not result.get("valid", false) and result["offshore"]:
            result["message"] = "Spawn is offshore (%.1fm below mapped land)." % offshore_depth
        elif not result.get("valid", false) and not str(result.get("reason", "")).is_empty():
            result["message"] = "Spawn blocked by %s." % str(result.get("reason", "terrain"))
    return result

func _update_camera(delta: float) -> void:
    if player == null or vehicle == null:
        return
    var look := touch.consume_look()
    camera_yaw -= look.x * 2.4
    camera_pitch = clamp(camera_pitch - look.y * 1.6, -0.65, 0.35)
    var driving := player.in_vehicle
    if driving != _camera_was_driving:
        _camera_was_driving = driving
        _camera_position_initialized = false
    var profile := _active_camera_profile(driving)
    var target: Vector3
    if driving:
        target = vehicle.body.global_position + Vector3.UP * float(profile.get("focus_height", 1.0))
    else:
        target = player.global_position + Vector3.UP * float(profile.get("focus_height", 1.30))
    var yaw := camera_yaw
    if driving:
        yaw += vehicle.body.rotation.y
    var pitch := camera_pitch * float(profile.get("pitch_scale", 0.46))
    var distance := float(profile.get("distance", 6.2))
    var height := float(profile.get("height", 2.45))
    var offset_local := Vector3(0, height, distance)
    offset_local = offset_local.rotated(Vector3.RIGHT, pitch)
    offset_local = offset_local.rotated(Vector3.UP, yaw)
    var ideal_position := target + offset_local
    ideal_position.y = maxf(ideal_position.y, target.y + float(profile.get("minimum_height", 1.4)))
    var blocked_position := _camera_collision_adjusted(target, ideal_position)
    var smoothing := float(profile.get("smoothing", 8.0))
    var reduced := touch.settings.reduced_motion == true
    if not _camera_position_initialized or reduced:
        camera.global_position = blocked_position
        _camera_position_initialized = true
    else:
        var weight := 1.0 - exp(-maxf(delta, 0.0) * smoothing)
        camera.global_position = camera.global_position.lerp(blocked_position, clampf(weight, 0.0, 1.0))
    camera.look_at(target, Vector3.UP)

func restore_snapshot(snapshot: Dictionary) -> void:
    day_hour = float(snapshot.get("day_hour", day_hour))
    current_parish = str(snapshot.get("parish", "Saint George"))
    var saved_offset: Array = snapshot.get("world_offset", [0.0, 0.0, 0.0])
    var restored_offset := Vector3(float(saved_offset[0]), float(saved_offset[1]), float(saved_offset[2]))
    var offset_delta := restored_offset - streamer.world_offset
    if not offset_delta.is_zero_approx():
        streamer.shift_world(offset_delta)
        streamer.world_offset = restored_offset
        building_streamer.shift_world(offset_delta)
    var vehicle_pos := nav.world_from_lat_lon(float(snapshot.get("vehicle_lat", 12.056)), float(snapshot.get("vehicle_lon", -61.748))) + streamer.world_offset
    vehicle_pos.y = float(snapshot.get("vehicle_y", vehicle_pos.y))
    var spawn_result := _validate_spawn_position(vehicle_pos, "Saved vehicle")
    if not spawn_result.valid:
        vehicle_pos = spawn_result.position
        _show_message(str(spawn_result.message))
    vehicle.body.global_position = vehicle_pos
    vehicle.odometer_m = float(snapshot.get("odometer_m", vehicle.odometer_m))
    vehicle.freeze_motion()
    var model := str(snapshot.get("vehicle_model", vehicle.model_id))
    if model != vehicle.model_id:
        vehicle.select_model(model)
    player._set_occupied(snapshot.get("in_vehicle", true) == true)
    if not player.in_vehicle:
        var player_pos := nav.world_from_lat_lon(float(snapshot.get("player_lat", 12.056)), float(snapshot.get("player_lon", -61.748))) + streamer.world_offset
        player_pos.y = float(snapshot.get("player_y", player_pos.y))
        spawn_result = _validate_spawn_position(player_pos, "Saved player")
        if not spawn_result.valid:
            player_pos = spawn_result.position
            _show_message(str(spawn_result.message))
        player.global_position = player_pos
        player.velocity = Vector3.ZERO
    else:
        player.global_position = vehicle.body.global_position
    streamer.set_focus(vehicle.body.global_position if player.in_vehicle else player.global_position)

func _show_custom_settings() -> void:
    if custom_settings == null:
        custom_settings = CustomSettingsScript.new()
        add_child(custom_settings)
        custom_settings.close_requested.connect(func ():
            custom_settings.visible = false
        )
        custom_settings.settings_changed.connect(func (quality: String, render_scale: float, reduced_motion: bool, shadows: bool):
            set_quality(quality)
            touch.set_render_scale(render_scale)
            touch.set_reduced_motion(reduced_motion)
            touch.set_shadows(shadows)
            get_viewport().scaling_3d_scale = render_scale
            if sun != null:
                sun.shadow_enabled = shadows
            _show_message("Display settings updated")
        )
    custom_settings.configure(
        visuals.quality,
        float(touch.settings.render_scale),
        touch.settings.reduced_motion == true,
        visuals.profile().shadows == true)
    custom_settings.visible = true
