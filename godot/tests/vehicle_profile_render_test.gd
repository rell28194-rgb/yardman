extends SceneTree

# Actual-render gate for the three production fallback silhouettes. This is
# intentionally independent of private hero media: public CI must prove that a
# missing private pack never collapses Crown, Mark X and 992 into one sedan.
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const ModelScript = preload("res://scripts/vehicle_model.gd")
const CAPTURE_SIZE := Vector2i(720, 480)
const BACKGROUND := Color(0.105, 0.135, 0.175)

var failures := 0
var output_dir := ""
var viewport: SubViewport
var scene: Node3D
var camera: Camera3D
var active_model: Node3D
var report := {"vehicles": []}

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_PROFILE_RENDER_TEST: " + message)

func _make_fixture() -> void:
    viewport = SubViewport.new()
    viewport.size = CAPTURE_SIZE
    viewport.own_world_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    viewport.msaa_3d = Viewport.MSAA_2X
    root.add_child(viewport)

    scene = Node3D.new()
    viewport.add_child(scene)

    var world_environment := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = BACKGROUND
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.78, 0.82, 0.90)
    environment.ambient_light_energy = 0.82
    environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
    world_environment.environment = environment
    scene.add_child(world_environment)

    var key := DirectionalLight3D.new()
    key.rotation_degrees = Vector3(-43.0, -31.0, 0.0)
    key.light_color = Color(1.0, 0.91, 0.80)
    key.light_energy = 2.2
    key.shadow_enabled = true
    scene.add_child(key)

    var rim := OmniLight3D.new()
    rim.position = Vector3(-3.4, 2.4, 2.5)
    rim.light_color = Color(0.50, 0.68, 1.0)
    rim.light_energy = 5.0
    rim.omni_range = 12.0
    scene.add_child(rim)

    camera = Camera3D.new()
    camera.position = Vector3(5.5, 2.55, 7.0)
    camera.fov = 42.0
    scene.add_child(camera)
    camera.look_at(Vector3(0.0, 0.72, 0.0), Vector3.UP)
    camera.current = true

func _set_vehicle(vehicle_id: String, yaw_degrees: float) -> Dictionary:
    if is_instance_valid(active_model):
        scene.remove_child(active_model)
        active_model.free()
    var profile := Catalog.profile(vehicle_id)
    active_model = ModelScript.new()
    active_model.name = "RenderVehicle_%s" % vehicle_id
    scene.add_child(active_model)
    active_model.call("build")
    var scale_data: Array = profile.get("visual_scale", [1.0, 1.0, 1.0])
    if scale_data.size() >= 3:
        active_model.scale = Vector3(float(scale_data[0]), float(scale_data[1]), float(scale_data[2]))
    active_model.rotation_degrees.y = yaw_degrees
    var runtime := root.get_node_or_null("VehicleVisualRuntime")
    _check(runtime != null and runtime.has_method("style_visual"), "VehicleVisualRuntime is unavailable in render fixture")
    return runtime.call("style_visual", active_model, vehicle_id) if runtime != null else {}

func _metrics(image: Image) -> Dictionary:
    var min_x := image.get_width()
    var max_x := -1
    var min_y := image.get_height()
    var max_y := -1
    var foreground := 0
    var luma_min := 1.0
    var luma_max := 0.0
    var rgb_sum := Vector3.ZERO
    var samples := 0
    for y in range(0, image.get_height(), 2):
        for x in range(0, image.get_width(), 2):
            var color := image.get_pixel(x, y)
            var difference := absf(color.r - BACKGROUND.r) + absf(color.g - BACKGROUND.g) + absf(color.b - BACKGROUND.b)
            if difference > 0.055:
                min_x = mini(min_x, x)
                max_x = maxi(max_x, x)
                min_y = mini(min_y, y)
                max_y = maxi(max_y, y)
                foreground += 1
                rgb_sum += Vector3(color.r, color.g, color.b)
                var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
                luma_min = minf(luma_min, luma)
                luma_max = maxf(luma_max, luma)
            samples += 1
    var bbox := Vector2i(0, 0)
    if max_x >= min_x and max_y >= min_y:
        bbox = Vector2i(max_x - min_x + 1, max_y - min_y + 1)
    var average := rgb_sum / maxf(float(foreground), 1.0)
    return {
        "foreground_samples": foreground,
        "total_samples": samples,
        "bbox_width": bbox.x,
        "bbox_height": bbox.y,
        "average_rgb": [average.x, average.y, average.z],
        "luma_range": maxf(luma_max - luma_min, 0.0),
    }

func _capture_vehicle(vehicle_id: String, yaw_degrees: float, suffix: String) -> Dictionary:
    var style_stats := _set_vehicle(vehicle_id, yaw_degrees)
    for frame in range(10):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := viewport.get_texture().get_image()
    _check(image != null and not image.is_empty(), "%s produced no rendered image" % vehicle_id)
    if image == null or image.is_empty():
        return {}
    var metrics := _metrics(image)
    _check(int(metrics.foreground_samples) > 1800, "%s has insufficient visible rendered geometry" % vehicle_id)
    _check(int(metrics.bbox_width) > 210, "%s rendered silhouette is unexpectedly narrow" % vehicle_id)
    _check(int(metrics.bbox_height) > 80, "%s rendered silhouette is unexpectedly short" % vehicle_id)
    _check(float(metrics.luma_range) > 0.12, "%s lacks material/lighting contrast" % vehicle_id)
    _check(bool(style_stats.get("profile_geometry", false)), "%s render did not use distinct profile geometry" % vehicle_id)
    _check(int(style_stats.get("stance_wheels", 0)) == 4, "%s render did not fit all four wheels" % vehicle_id)
    var file_name := "%s-%s.png" % [vehicle_id, suffix]
    _check(image.save_png(output_dir.path_join(file_name)) == OK, "Could not save %s capture" % vehicle_id)
    return {
        "vehicle_id": vehicle_id,
        "view": suffix,
        "image": file_name,
        "geometry_signature": str(style_stats.get("geometry_signature", "")),
        "stance_wheelbase_m": float(style_stats.get("stance_wheelbase_m", 0.0)),
        "stance_track_m": float(style_stats.get("stance_track_m", 0.0)),
        "metrics": metrics,
    }

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "A real renderer/display is required for vehicle presentation evidence")
        quit(1)
        return
    output_dir = OS.get_environment("YARDMAN_VEHICLE_CAPTURE_DIR")
    if output_dir.is_empty():
        var base := OS.get_environment("YARDMAN_RENDER_CAPTURE_DIR")
        output_dir = base.path_join("vehicles") if not base.is_empty() else ProjectSettings.globalize_path("user://vehicle-profile-captures")
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Could not create vehicle capture directory")
    _make_fixture()
    report["engine"] = Engine.get_version_info()
    report["method"] = RenderingServer.get_current_rendering_method()
    report["adapter"] = RenderingServer.get_video_adapter_name()
    report["scope"] = "Actual host-render validation of public fallback production vehicle silhouettes; private hero-mesh and Android-device acceptance remain separate"

    var signatures: Dictionary = {}
    for vehicle_id_value in Catalog.production_ids():
        var vehicle_id := str(vehicle_id_value)
        var three_quarter := await _capture_vehicle(vehicle_id, -24.0, "three-quarter")
        var side := await _capture_vehicle(vehicle_id, -90.0, "side")
        report.vehicles.append(three_quarter)
        report.vehicles.append(side)
        signatures[str(three_quarter.get("geometry_signature", ""))] = vehicle_id
    _check(signatures.size() == Catalog.production_ids().size(), "Rendered production cars do not retain three distinct geometry signatures")

    report["failures"] = failures
    var handle := FileAccess.open(output_dir.path_join("vehicle-profile-render-report.json"), FileAccess.WRITE)
    if handle != null:
        handle.store_string(JSON.stringify(report, "  ") + "\n")
        handle.close()
    else:
        _check(false, "Could not save vehicle render report")
    print("YARDMAN_VEHICLE_PROFILE_RENDER_TEST %s method=%s vehicles=3 captures=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", report.method, report.vehicles.size(), failures])
    if is_instance_valid(active_model):
        active_model.queue_free()
    viewport.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
