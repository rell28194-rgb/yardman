extends SceneTree

var scene
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _suppress_far_overview() -> void:
    # The acceptance runner uses software OpenGL. Building all 2,537 national
    # far-LOD sectors there can consume most of the 10-minute capture budget,
    # even though every acceptance frame is a local gameplay view. Keep the
    # real streamed terrain/roads/buildings and discard only the asynchronous
    # island-overview assembly in this test process.
    if scene == null or scene.terrain == null:
        return
    var terrain = scene.terrain
    if not terrain._far_build.is_empty():
        terrain._far_build.clear()
    if terrain._far_root != null and terrain._far_root.get_child_count() == 0:
        terrain._far_root.queue_free()
        terrain._far_root = null

func _wait_world() -> bool:
    for frame in range(3600):
        await process_frame
        _suppress_far_overview()
        if scene.world_ready and scene.car.is_on_floor() and scene.roads.inflight_count() == 0 and scene.terrain.inflight_count() == 0:
            if scene.buildings != null and scene.buildings.inflight_count() > 0:
                continue
            return true
    return false

func _capture(name_value: String) -> bool:
    for frame in range(8):
        await process_frame
        _suppress_far_overview()
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
    # Kingston is included specifically to expose dense urban building massing;
    # St. Ann and Manchester remain stable comparisons for lower-density scenes.
    for parish in ["Kingston", "St. Ann", "Manchester"]:
        scene.goto_parish(parish)
        scene.day_hour = 10.0
        if not await _wait_world():
            push_error("CAPTURE_TEST: Failed to prepare " + parish)
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
    scene.hud.set_menu_open(false)
    var parish_navigation = scene.hud.get_node_or_null("ParishNavigation")
    if parish_navigation == null:
        push_error("CAPTURE_TEST: Parish navigation node missing")
        quit(1)
        return
    parish_navigation.set_map_open(true)
    if not await _capture("yardman-parish-map"):
        push_error("CAPTURE_TEST: Parish map capture failed")
        quit(1)
        return
    parish_navigation.set_map_open(false)
    print("YARDMAN_CAPTURE_TEST PASS actual_gl_frames=6 renderer=" + RenderingServer.get_video_adapter_name())
    scene.queue_free()
    await process_frame
    quit(0)