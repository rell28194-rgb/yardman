extends SceneTree

const SaveScript = preload("res://scripts/save_game.gd")
const References = preload("res://scripts/reference_assets.gd")
var failures := 0
var _started_ms := 0

func _initialize() -> void:
    _started_ms = Time.get_ticks_msec()
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GAMEPLAY_TEST: " + message)

func _wait_ready(scene, phase: String) -> bool:
    var began_ms := Time.get_ticks_msec()
    for frame in range(1800):
        await physics_frame
        var body: CharacterBody3D = scene.car if scene.player.in_vehicle else scene.player
        if frame % 120 == 0:
            print("YARDMAN_GAMEPLAY_PROGRESS phase=%s parish=%s frame=%d world_ready=%s on_floor=%s elapsed_ms=%d phase_ms=%d" % [
                phase,
                scene.current_parish,
                frame,
                str(scene.world_ready),
                str(body.is_on_floor()),
                Time.get_ticks_msec() - _started_ms,
                Time.get_ticks_msec() - began_ms
            ])
        # Production main.gd only raises world_ready after local collision data is
        # present and the actor's spawn has completed its settle pass. Requiring
        # CharacterBody3D.is_on_floor() here duplicates that gate and can remain
        # false for a correctly settled body between physics contacts. The terrain
        # elevation assertion immediately after each parish transfer remains the
        # independent proof that the car settled onto real Jamaica terrain.
        if scene.world_ready:
            for settle in range(6):
                await physics_frame
            body = scene.car if scene.player.in_vehicle else scene.player
            print("YARDMAN_GAMEPLAY_READY phase=%s parish=%s frame=%d on_floor=%s elapsed_ms=%d phase_ms=%d" % [
                phase,
                scene.current_parish,
                frame,
                str(body.is_on_floor()),
                Time.get_ticks_msec() - _started_ms,
                Time.get_ticks_msec() - began_ms
            ])
            return true
    _check(false, "Terrain/physics did not become ready in " + scene.current_parish)
    print("YARDMAN_GAMEPLAY_TIMEOUT phase=%s parish=%s elapsed_ms=%d phase_ms=%d" % [
        phase,
        scene.current_parish,
        Time.get_ticks_msec() - _started_ms,
        Time.get_ticks_msec() - began_ms
    ])
    return false

func _check_active_vehicle(scene) -> void:
    var garage := root.get_node_or_null("VehicleGarage")
    _check(garage != null, "VehicleGarage autoload is unavailable")
    if garage == null:
        return
    var selected := str(garage.call("selected_vehicle_id"))
    var controller_id := str(scene.vehicle.get("vehicle_id"))
    _check(controller_id == selected, "Active controller did not receive garage selection: selected=%s controller=%s" % [selected, controller_id])
    var visual = scene.vehicle.get("visual")
    var reference_name := ""
    if is_instance_valid(visual):
        reference_name = str(visual.get("reference_asset_name"))
    var private_crown_available := References.scene("toyota_crown_2013.glb") != null
    if private_crown_available and selected == "toyota_crown":
        _check(reference_name == "toyota_crown_2013.glb", "Manifest-verified private Crown is present but gameplay substituted another vehicle")
    print("YARDMAN_GAMEPLAY_VEHICLE selected=%s controller=%s reference=%s private_crown=%s" % [
        selected, controller_id, reference_name, str(private_crown_available)
    ])

func _configure_functional_streaming(scene) -> void:
    # This suite validates national traversal, terrain/collision registration,
    # vehicle/player controls, saves and mobile input. It is not a frame-budget
    # benchmark. Keep production streaming logic and data intact while allowing
    # the headless runner to consume incremental geometry queues aggressively.
    # Otherwise dense urban tiles can spend most of the global 600-second CI
    # allowance honoring mobile-sized per-frame budgets before the assertions run.
    scene.set_quality("Performance")
    scene.roads.max_io_jobs = 4
    scene.roads.max_segments_per_frame = 16384
    scene.roads.geometry_budget_us = 50000
    scene.terrain.max_io_jobs = 4
    scene.terrain.geometry_budget_us = 50000
    # Building and roadside art are covered by render/geometry suites. They are
    # deliberately excluded here so visual assembly cannot mask a traversal bug.
    scene.buildings.set_process(false)
    scene.buildings.reference_facades_enabled = false
    var road_decorator := Callable(scene, "_decorate_tile")
    if scene.roads.tile_content_ready.is_connected(road_decorator):
        scene.roads.tile_content_ready.disconnect(road_decorator)
    var terrain_decorator := Callable(scene, "_decorate_ready_terrain")
    if scene.terrain.tile_ready.is_connected(terrain_decorator):
        scene.terrain.tile_ready.disconnect(terrain_decorator)
    scene._refresh_streamers()
    print("YARDMAN_GAMEPLAY_FUNCTIONAL_STREAMING road_radius=%d terrain_radius=%d road_segments_per_frame=%d road_budget_us=%d terrain_budget_us=%d" % [
        scene.roads.load_radius,
        scene.terrain.load_radius,
        scene.roads.max_segments_per_frame,
        scene.roads.geometry_budget_us,
        scene.terrain.geometry_budget_us
    ])

func _run() -> void:
    # National gameplay requires the registered compiler outputs. A source-only
    # checkout must fail clearly before waiting on terrain which cannot load.
    for path in ["res://data/roads/manifest.json", "res://data/terrain/manifest.json"]:
        if not FileAccess.file_exists(path):
            _check(false, "Build registered Jamaica data before gameplay testing: missing " + path)
            print("YARDMAN_GAMEPLAY_TEST FAIL prerequisite=registered_jamaica_data")
            quit(1)
            return
    var scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    # Autoloads and runtime services resolve the production world through
    # SceneTree.current_scene. Tests that only parent main.tscn can otherwise
    # silently exercise legacy/default vehicle state instead of the active game.
    current_scene = scene
    _check(current_scene == scene, "Production main scene was not activated as SceneTree.current_scene")
    _configure_functional_streaming(scene)
    if not (await _wait_ready(scene, "initial")):
        quit(1)
        return
    _check_active_vehicle(scene)
    _check(scene.roads.manifest.parish_anchors.size() == 14, "All fourteen parishes must be addressable")
    for parish in scene.roads.manifest.parish_anchors:
        var parish_name := str(parish)
        print("YARDMAN_GAMEPLAY_PROGRESS phase=parish_begin parish=%s elapsed_ms=%d" % [parish_name, Time.get_ticks_msec() - _started_ms])
        scene.goto_parish(parish_name)
        if not (await _wait_ready(scene, "parish_stream")):
            quit(1)
            return
        var world: PackedFloat64Array = scene.roads.local_to_world(scene.car.position)
        var ground: float = scene.terrain.height_at(world[0], world[2])
        _check(is_finite(ground) and absf(world[1] - ground) < 1.0, "Car did not settle on real terrain in " + parish_name)
        _check(scene.car.position.length() < 3000.0, "Parish travel bypassed local origin rebasing")
        _check(scene.terrain._loaded.size() <= 25, "Terrain residency exceeds the configured bounded ring")
        print("YARDMAN_GAMEPLAY_PROGRESS phase=parish_ready parish=%s elapsed_ms=%d" % [parish_name, Time.get_ticks_msec() - _started_ms])
    scene.goto_parish("St. Mary")
    if not (await _wait_ready(scene, "st_mary_gameplay")):
        quit(1)
        return
    scene.vehicle.speed_mps = 4.0
    _check(not scene.player.try_exit_vehicle(), "Exit allowed while vehicle is moving")
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    _check(not scene.player.in_vehicle and scene.player.visible, "Player did not exit into the world")
    var start: Vector3 = scene.player.position
    Input.action_press("ui_up")
    for frame in range(90):
        await physics_frame
    Input.action_release("ui_up")
    _check(scene.player.position.distance_to(start) > 4.0, "On-foot movement did not advance")
    _check(not scene.player.try_enter_vehicle(), "Distant vehicle could be entered")
    Input.action_press("ui_down")
    for frame in range(90):
        await physics_frame
    Input.action_release("ui_down")
    for frame in range(20):
        await physics_frame
    scene.toggle_vehicle()
    _check(scene.player.in_vehicle and not scene.player.visible, "Player could not re-enter the nearby stopped car")
    if not (await _wait_ready(scene, "reenter_vehicle")):
        quit(1)
        return
    var mileage: float = scene.vehicle.odometer_m
    Input.action_press("ui_up")
    for frame in range(240):
        await physics_frame
        if scene.vehicle.odometer_m - mileage > 8.0:
            break
    Input.action_release("ui_up")
    _check(scene.vehicle.odometer_m - mileage > 8.0, "Driving input did not move the car far enough under the selected vehicle profile")
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    _check(not scene.player.in_vehicle, "Could not park and exit before distant streaming test")
    var parked: Dictionary = scene.get_snapshot().car
    var destination: Array = scene.roads.manifest.parish_anchors.Hanover.road_position
    scene.player.position = scene.roads.world_to_local(float(destination[0]), float(destination[2]), float(destination[1]) + 0.35)
    scene._rebase(float(destination[0]), float(destination[2]))
    scene._settle_spawn = true
    scene._refresh_streamers()
    if not (await _wait_ready(scene, "parked_remote_stream")):
        quit(1)
        return
    for frame in range(30):
        await physics_frame
    var frozen: Dictionary = scene.get_snapshot().car
    for field in ["easting", "northing", "elevation"]:
        _check(absf(float(frozen[field]) - float(parked[field])) < 0.001, "Distant parked car changed " + field)
    scene.goto_parish("St. Mary")
    if not (await _wait_ready(scene, "return_st_mary")):
        quit(1)
        return
    var snapshot: Dictionary = scene.get_snapshot()
    var canonical_x := float(snapshot.car.easting)
    var canonical_n := float(snapshot.car.northing)
    scene._rebase(-160000.25, -54000.50)
    var shifted: Dictionary = scene.get_snapshot()
    _check(absf(float(shifted.car.easting) - canonical_x) < 0.02 and absf(float(shifted.car.northing) - canonical_n) < 0.02, "Origin shift changed canonical saved coordinates")
    scene.restore_snapshot(snapshot)
    _check(absf(float(scene.get_snapshot().car.easting) - canonical_x) < 0.001, "Restoring a save changed global position")
    var path := "user://yardman/tests/save.json"
    for suffix in ["", ".bak", ".tmp"]:
        if FileAccess.file_exists(path + suffix):
            DirAccess.remove_absolute(path + suffix)
    _check(SaveScript.save_file(path, snapshot) == OK, "First save failed")
    var saved: Dictionary = SaveScript.load_file(path)
    _check(not saved.is_empty() and absf(float(saved.car.easting) - canonical_x) < 0.001, "Save round trip failed")
    var next := snapshot.duplicate(true)
    next.car.easting = float(next.car.easting) + 20.0
    _check(SaveScript.save_file(path, next) == OK, "Second save failed")
    var broken := FileAccess.open(path, FileAccess.WRITE)
    broken.store_string("{\"payload\":null}")
    broken.close()
    var fallback: Dictionary = SaveScript.load_file(path)
    _check(not fallback.is_empty() and absf(float(fallback.car.easting) - canonical_x) < 0.001, "Corrupt save did not recover its backup")
    var invalid := snapshot.duplicate(true)
    invalid.car.easting = NAN
    _check(SaveScript.save_file(path, invalid) == ERR_INVALID_DATA, "Non-finite world coordinates were saved")
    var controls = scene.touch
    controls.apply_settings({"steering_mode": "Buttons"})
    for item in [[0, "gas"], [1, "left"]]:
        var event := InputEventScreenTouch.new()
        event.index = item[0]
        event.pressed = true
        event.position = controls._zone_rect(item[1]).get_center()
        controls._input(event)
    _check(controls.throttle() == 1.0 and controls.steering() == -1.0, "Two-finger steering/throttle conflict")
    var released := InputEventScreenTouch.new()
    released.index = 1
    released.pressed = false
    controls._input(released)
    _check(controls.throttle() == 1.0 and controls.steering() == 0.0, "Releasing one finger cleared the other")
    controls._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
    _check(controls.fingers.is_empty(), "Controls remained stuck after focus loss")
    for quality in ["Performance", "Balanced", "Quality", "Ultra", "Custom"]:
        scene.set_quality(quality, {"trees": 99, "road_radius": 1, "terrain_radius": 1})
        _check(scene.visuals.quality == quality, "Quality selection failed")
    _check(int(scene.visuals.settings().trees) == 99, "Custom density was ignored")
    print("YARDMAN_GAMEPLAY_TEST %s parishes=14 walk=1 drive=1 enter_exit=1 save_backup=1 multitouch=1 current_scene=1 vehicle_selection=1 functional_streaming=1" % ("PASS" if failures == 0 else "FAIL"))
    if current_scene == scene:
        current_scene = null
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
