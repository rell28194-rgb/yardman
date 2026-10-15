extends SceneTree

var scene
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _local_stream_ready() -> bool:
    if scene == null or not scene.world_ready or not scene.car.is_on_floor():
        return false
    var world: PackedFloat64Array = scene.roads.local_to_world(scene.car.position)
    var tile: Vector2i = scene.roads.coordinates.tile_for(world[0], world[2])
    var road_key: String = scene.roads._tile_key(tile.x, tile.y)
    if not scene.roads._loaded.has(road_key):
        return false
    if not scene.terrain.is_tile_ready(tile):
        return false
    return true

func _wait_world(parish: String) -> bool:
    # Captures need the player-facing local road/terrain/collision to be ready,
    # not every background tile in the Ultra streaming radius. Requiring global
    # inflight_count()==0 made this visual smoke gate scale with the complete
    # national dataset and blocked an otherwise valid Android export.
    var deadline_ms := Time.get_ticks_msec() + 150000
    var stable_frames := 0
    while Time.get_ticks_msec() < deadline_ms:
        await process_frame
        if _local_stream_ready():
            stable_frames += 1
            if stable_frames >= 12:
                print("CAPTURE_TEST_READY parish=%s road_inflight=%d terrain_inflight=%d building_inflight=%d" % [
                    parish, scene.roads.inflight_count(), scene.terrain.inflight_count(), scene.buildings.inflight_count()
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
    for frame in range(8):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    if picture == null or picture.is_empty():
        return false
    return picture.save_png(output_dir.path_join(name_value + ".png")) == OK

func _run() -> void:
    output_dir = OS.get_environment("YARDMAN_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("res://build/captures")
    DirAccess.make_dir_recursive_absolute(output_dir)
    scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    scene.set_quality("Ultra")
    scene.touch._touch_seen = true
    for parish in ["St. Ann", "Manchester"]:
        scene.goto_parish(parish)
        scene.day_hour = 10.0
        if not await _wait_world(parish):
            push_error("CAPTURE_TEST: Failed to prepare local streamed world for " + parish)
            quit(1)
            return
        if not await _capture("yardman-" + parish.to_lower().replace(".", "").replace(" ", "-")):
            push_error("CAPTURE_TEST: Could not save actual engine frame")
            quit(1)
            return
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    if scene.player.in_vehicle or not await _capture("yardman-walking"):
        push_error("CAPTURE_TEST: Walking view failed")
        quit(1)
        return
    scene.hud.set_menu_open(true)
    if not await _capture("yardman-settings"):
        quit(1)
        return
    print("YARDMAN_CAPTURE_TEST PASS actual_gl_frames=4 renderer=" + RenderingServer.get_video_adapter_name())
    scene.queue_free()
    await process_frame
    quit(0)
