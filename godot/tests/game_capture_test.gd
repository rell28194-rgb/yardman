extends SceneTree

var scene
var output_dir := ""

const CAPTURE_READY_FRAMES := 24
const CAPTURE_MAX_FRAMES := 1200
const LOCAL_BUILDING_CELL_RADIUS := 1

func _initialize() -> void:
    call_deferred("_run")

func _suppress_far_overview() -> void:
    # The acceptance runner uses software OpenGL. Building all 2,537 national
    # terrain overview sectors there can consume most of the capture budget.
    # This affects only the CI process: real runtime far terrain/road HLODs stay
    # enabled. Local streamed terrain/roads/buildings remain fully real.
    if scene == null or scene.terrain == null:
        return
    var terrain = scene.terrain
    if not terrain._far_build.is_empty():
        terrain._far_build.clear()
    if terrain._far_root != null and terrain._far_root.get_child_count() == 0:
        terrain._far_root.queue_free()
        terrain._far_root = null

func _local_buildings_ready(world_x: float, world_z: float) -> bool:
    if scene.buildings == null or scene.buildings.manifest.is_empty():
        return true
    var streamer = scene.buildings
    var center := Vector2i(floori(world_x / streamer.cell_size), floori(world_z / streamer.cell_size))
    var required := 0
    for dz in range(-LOCAL_BUILDING_CELL_RADIUS, LOCAL_BUILDING_CELL_RADIUS + 1):
        for dx in range(-LOCAL_BUILDING_CELL_RADIUS, LOCAL_BUILDING_CELL_RADIUS + 1):
            var cell := center + Vector2i(dx, dz)
            if not streamer._has_cell(cell):
                continue
            required += 1
            if not streamer._loaded.has(streamer._key(cell)):
                return false
    # Empty rural cells are valid; populated captures must have their immediate
    # source cells resident, not the entire 1.45 km Ultra building queue.
    return required == 0 or required <= streamer._loaded.size()

func _local_surface_ready() -> bool:
    if scene == null or scene.roads == null or scene.terrain == null:
        return false
    var world: PackedFloat64Array = scene.roads.local_to_world(scene.car.position)
    return bool(scene.world_ready) \
        and bool(scene.car.is_on_floor()) \
        and bool(scene.roads.is_world_position_ready(world[0], world[2])) \
        and bool(scene.terrain.is_world_position_ready(world[0], world[2])) \
        and _local_buildings_ready(world[0], world[2])

func _wait_world() -> bool:
    # Acceptance is intentionally local: a playable camera view must not wait
    # for every Ultra-distance tile in the background queues. Requiring global
    # inflight_count()==0 made a correct local world look permanently loading
    # while unrelated 4 km tiles were still compiling under llvmpipe.
    var ready_frames := 0
    for frame in range(CAPTURE_MAX_FRAMES):
        await process_frame
        _suppress_far_overview()
        if _local_surface_ready():
            ready_frames += 1
            if ready_frames >= CAPTURE_READY_FRAMES:
                print("CAPTURE_TEST: local world ready after %d frames; road_pending=%d terrain_pending=%d building_pending=%d" % [
                    frame + 1, scene.roads.inflight_count(), scene.terrain.inflight_count(), scene.buildings.inflight_count()])
                return true
        else:
            ready_frames = 0
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