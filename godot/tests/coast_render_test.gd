extends SceneTree

# Optional real GL inspection of compiled OSM coast and beach geometry. These
# source-polygon interior coordinates use the national EPSG:3448 origin.
const LOCATIONS := [
    {"name": "turtle-beach", "parish": "St. Ann", "osm_way": 59584393,
        "x": -33049.639, "z": -48530.022, "offset": Vector3(45, 58, -120)},
    {"name": "seven-mile-beach", "parish": "Westmoreland", "osm_way": 578136135,
        "x": -163378.545, "z": -37689.869, "offset": Vector3(-135, 54, -35)},
]
var scene
var output_dir := ""
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    failures += 1
    push_error("COAST_RENDER_TEST: " + message)

func _wait_coast(tile: Vector2i) -> bool:
    for frame in range(4200):
        await process_frame
        if not scene.terrain.is_tile_ready(tile):
            continue
        if scene.terrain.inflight_count() > 0 or scene.roads.inflight_count() > 0:
            continue
        # Complete the distant ocean sectors before capturing a horizon.
        if not scene.terrain._far_build.is_empty():
            continue
        return true
    return false

func _capture(filename: String) -> bool:
    for frame in range(10):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    if picture == null or picture.is_empty():
        _fail("No actual engine image")
        return false
    if picture.save_png(output_dir.path_join(filename + ".png")) != OK:
        _fail("Could not save " + filename)
        return false
    return true

func _view_location(location: Dictionary) -> bool:
    var x: float = location.x
    var z: float = location.z
    scene.current_parish = str(location.parish)
    scene._rebase(x, z)
    scene.car.position = scene.roads.world_to_local(x, z, 10.0)
    scene.player.position = scene.car.position
    scene._car_world = PackedFloat64Array([x, 10.0, z])
    scene.vehicle.reset_motion()
    scene._refresh_streamers()
    var tile: Vector2i = scene.roads.coordinates.tile_for(x, z)
    if not await _wait_coast(tile):
        _fail("Coastal tile not prepared for " + str(location.name))
        return false
    var tile_root: Node3D = scene.terrain._loaded[scene.terrain._tile_key(tile.x, tile.y)]
    if not tile_root.has_node("RegisteredOcean") or not tile_root.has_node("SourcedBeach"):
        _fail("Mapped ocean or source beach absent at " + str(location.name))
        return false
    var height: float = scene.terrain.height_at(x, z)
    if not is_finite(height):
        _fail("Source-polygon interior was classified as water at " + str(location.name))
        return false
    scene.car.position.y = height + 0.04
    scene.player.position = scene.car.position
    scene._car_world = PackedFloat64Array([x, height + 0.04, z])
    var center: Vector3 = scene.roads.world_to_local(x, z, maxf(height, 0.0))
    scene.camera.position = center + location.offset
    scene.camera.look_at(center)
    scene.camera.fov = 62.0
    scene.hud.visible = false
    scene.touch.visible = false
    if not await _capture(str(location.name) + "-overview"):
        return false
    # Render a close shoreline view in the same game scene, rather than an
    # invented terrain fixture. Ocean-facing directions follow each coast.
    var toward_sea := Vector3(0, 0, -1) if str(location.name) == "turtle-beach" else Vector3(-1, 0, 0)
    scene.camera.position = center + Vector3(0, 3.5, 0) - toward_sea * 7.0
    scene.camera.look_at(center + toward_sea * 30.0 + Vector3.UP * 0.9)
    scene.camera.fov = 72.0
    if not await _capture(str(location.name) + "-shore"):
        return false
    # A shifted scene must retain the exact registered sea-level surface.
    var water: MeshInstance3D = tile_root.get_node("RegisteredOcean")
    var water_world: PackedFloat64Array = scene.roads.local_to_world(water.global_position)
    scene._rebase(x + 768.0, z - 512.0)
    var water_after: PackedFloat64Array = scene.roads.local_to_world(water.global_position)
    for axis in range(3):
        if absf(water_after[axis] - water_world[axis]) > 0.001:
            _fail("Coast moved in geographic coordinates after rebase")
    if not await _capture(str(location.name) + "-rebased"):
        return false
    print("YARDMAN_COAST_RENDER location=%s source_way=%d world_x=%.3f world_z=%.3f height_m=%.3f" %
        [location.name, location.osm_way, x, z, height])
    return true

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _fail("An actual GL display is required")
        quit(1)
        return
    output_dir = OS.get_environment("YARDMAN_COAST_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("res://build/coast-captures")
    DirAccess.make_dir_recursive_absolute(output_dir)
    scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    # The view is an inspection camera. Gameplay remains covered by its own
    # physics tests; do not move the test camera with the follow-camera loop.
    scene.set_physics_process(false)
    scene.set_quality("Balanced")
    scene.day_hour = 10.0
    scene.visuals.update_daylight(10.0, scene.environment)
    for location: Dictionary in LOCATIONS:
        if not await _view_location(location):
            break
    if failures == 0:
        print("YARDMAN_COAST_RENDER_TEST PASS actual_gl_frames=6 registered_locations=2 rebase=1 renderer=" + RenderingServer.get_video_adapter_name())
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
