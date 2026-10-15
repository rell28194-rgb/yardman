extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
var scene
var output_dir := ""
var _started_ms := 0

func _initialize() -> void:
    _started_ms = Time.get_ticks_msec()
    print("YARDMAN_CAPTURE_PROGRESS phase=initialize elapsed_ms=0")
    call_deferred("_run")

func _local_stream_ready() -> bool:
    # Production world_ready already requires the local collision footprint and
    # spawn-settle pass. is_on_floor() is diagnostic only: it can be false on a
    # perfectly settled CharacterBody3D between contacts and must not deadlock a
    # visual capture gate after the world itself is ready.
    if scene == null or not scene.world_ready:
        return false
    var world: PackedFloat64Array = scene.roads.local_to_world(scene.car.position)
    var tile: Vector2i = scene.roads.coordinates.tile_for(world[0], world[2])
    var road_key: String = scene.roads._tile_key(tile.x, tile.y)
    if not scene.roads._loaded.has(road_key):
        return false
    if not scene.terrain.is_tile_ready(tile):
        return false
    return true

func _active_vehicle_contract() -> bool:
    var garage := root.get_node_or_null("VehicleGarage")
    if garage == null:
        push_error("CAPTURE_TEST: VehicleGarage autoload unavailable")
        return false
    var selected := str(garage.call("selected_vehicle_id"))
    var controller_id := str(scene.vehicle.get("vehicle_id"))
    var visual = scene.vehicle.get("visual")
    var reference_name := ""
    if is_instance_valid(visual):
        reference_name = str(visual.get("reference_asset_name"))
    var private_crown_available := References.scene("toyota_crown_2013.glb") != null
    print("YARDMAN_CAPTURE_VEHICLE selected=%s controller=%s reference=%s private_crown=%s" % [
        selected, controller_id, reference_name, str(private_crown_available)
    ])
    if controller_id != selected:
        push_error("CAPTURE_TEST: Active controller does not match garage selection")
        return false
    if private_crown_available and selected == "toyota_crown" and reference_name != "toyota_crown_2013.glb":
        push_error("CAPTURE_TEST: Manifest-verified private Crown is present but capture substituted another vehicle")
        return false
    return true

func _configure_capture_streaming() -> void:
    # Keep Ultra materials/lighting and the production render path, but bound the
    # capture to the local neighbourhood actually visible in a 1280x720 frame.
    # National traversal/streaming radius is covered separately. This prevents
    # background HLOD queues from consuming most of the renderer smoke timeout.
    scene.roads.load_radius = 1
    scene.roads.max_io_jobs = 4
    scene.roads.max_segments_per_frame = 8192
    scene.roads.geometry_budget_us = 40000
    scene.terrain.load_radius = 1
    scene.terrain.max_io_jobs = 4
    scene.terrain.geometry_budget_us = 40000
    scene.buildings.draw_distance = 450.0
    scene.buildings.max_loaded_cells = 64
    scene.buildings.max_io_jobs = 4
    scene.buildings.max_buildings_per_frame = 160
    scene.buildings.geometry_budget_us = 40000
    scene._refresh_streamers()
    print("YARDMAN_CAPTURE_STREAMING road_radius=%d terrain_radius=%d building_distance=%.0f road_budget_us=%d terrain_budget_us=%d building_budget_us=%d" % [
        scene.roads.load_radius,
        scene.terrain.load_radius,
        scene.buildings.draw_distance,
        scene.roads.geometry_budget_us,
        scene.terrain.geometry_budget_us,
        scene.buildings.geometry_budget_us
    ])

func _wait_world(parish: String) -> bool:
    # Captures need the player-facing local road/terrain/collision to be ready,
    # not every background tile in the Ultra streaming radius. Requiring global
    # inflight_count()==0 made this visual smoke gate scale with the complete
    # national dataset and blocked an otherwise valid Android export.
    var deadline_ms := Time.get_ticks_msec() + 150000
    var stable_frames := 0
    var next_report_ms := Time.get_ticks_msec()
    while Time.get_ticks_msec() < deadline_ms:
        await process_frame
        var now_ms := Time.get_ticks_msec()
        if now_ms >= next_report_ms:
            print("YARDMAN_CAPTURE_PROGRESS phase=wait_world parish=%s elapsed_ms=%d stable_frames=%d world_ready=%s floor=%s road_inflight=%d terrain_inflight=%d building_inflight=%d" % [
                parish,
                now_ms - _started_ms,
                stable_frames,
                str(scene.world_ready),
                str(scene.car.is_on_floor()),
                scene.roads.inflight_count(),
                scene.terrain.inflight_count(),
                scene.buildings.inflight_count()
            ])
            next_report_ms = now_ms + 5000
        if _local_stream_ready():
            stable_frames += 1
            if stable_frames >= 12:
                print("CAPTURE_TEST_READY parish=%s floor=%s road_inflight=%d terrain_inflight=%d building_inflight=%d" % [
                    parish, str(scene.car.is_on_floor()), scene.roads.inflight_count(), scene.terrain.inflight_count(), scene.buildings.inflight_count()
                ])
                return true
        else:
            stable_frames = 0
    print("CAPTURE_TEST_TIMEOUT parish=%s world_ready=%s floor=%s road_inflight=%d terrain_inflight=%d building_inflight=%d" % [
        parish, str(scene.world_ready), str(scene.car.is_on_floor()), scene.roads.inflight_count(),
        scene.terrain.inflight_count(), scene.buildings.inflight_count()
    ])
    return false

func _capture(name_value: String) -> bool:
    print("YARDMAN_CAPTURE_PROGRESS phase=capture_begin name=%s elapsed_ms=%d" % [name_value, Time.get_ticks_msec() - _started_ms])
    for frame in range(8):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    if picture == null or picture.is_empty():
        print("YARDMAN_CAPTURE_PROGRESS phase=capture_empty name=%s elapsed_ms=%d" % [name_value, Time.get_ticks_msec() - _started_ms])
        return false
    var result := picture.save_png(output_dir.path_join(name_value + ".png")) == OK
    print("YARDMAN_CAPTURE_PROGRESS phase=capture_end name=%s ok=%s elapsed_ms=%d" % [name_value, str(result), Time.get_ticks_msec() - _started_ms])
    return result

func _run() -> void:
    output_dir = OS.get_environment("YARDMAN_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("res://build/captures")
    DirAccess.make_dir_recursive_absolute(output_dir)
    print("YARDMAN_CAPTURE_PROGRESS phase=scene_load output_dir=%s elapsed_ms=%d" % [output_dir, Time.get_ticks_msec() - _started_ms])
    scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    current_scene = scene
    scene.set_quality("Ultra")
    _configure_capture_streaming()
    scene.touch._touch_seen = true
    var vehicle_checked := false
    for parish in ["St. Ann", "Manchester"]:
        print("YARDMAN_CAPTURE_PROGRESS phase=parish_begin parish=%s elapsed_ms=%d" % [parish, Time.get_ticks_msec() - _started_ms])
        scene.goto_parish(parish)
        scene.day_hour = 10.0
        if not await _wait_world(parish):
            push_error("CAPTURE_TEST: Failed to prepare local streamed world for " + parish)
            quit(1)
            return
        if not vehicle_checked:
            if not _active_vehicle_contract():
                quit(1)
                return
            vehicle_checked = true
        if not await _capture("yardman-" + parish.to_lower().replace(".", "").replace(" ", "-")):
            push_error("CAPTURE_TEST: Could not save actual engine frame")
            quit(1)
            return
    print("YARDMAN_CAPTURE_PROGRESS phase=walking_transition elapsed_ms=%d" % [Time.get_ticks_msec() - _started_ms])
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    if scene.player.in_vehicle or not await _capture("yardman-walking"):
        push_error("CAPTURE_TEST: Walking view failed")
        quit(1)
        return
    print("YARDMAN_CAPTURE_PROGRESS phase=settings_open elapsed_ms=%d" % [Time.get_ticks_msec() - _started_ms])
    scene.hud.set_menu_open(true)
    if not await _capture("yardman-settings"):
        quit(1)
        return
    print("YARDMAN_CAPTURE_TEST PASS actual_gl_frames=4 renderer=" + RenderingServer.get_video_adapter_name())
    if current_scene == scene:
        current_scene = null
    scene.queue_free()
    await process_frame
    quit(0)
