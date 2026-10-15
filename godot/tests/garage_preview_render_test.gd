extends SceneTree

# Exercise the real garage SubViewport, camera and production styling. Removing
# only the studio environment is the A/B control; paint and lights stay fixed.
const Catalog = preload("res://scripts/vehicle_catalog.gd")
var failures := 0
var output_dir := ""
var garage: Node
var viewport: SubViewport
var model: Node3D

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GARAGE_PREVIEW_RENDER_TEST: " + message)

func _capture() -> Image:
    for frame in range(12):
        await process_frame
    await RenderingServer.frame_post_draw
    return viewport.get_texture().get_image()

func _metrics(image: Image, background: Image) -> Dictionary:
    var values: Array[float] = []
    var minimum := Vector2i(image.get_width(), image.get_height())
    var maximum := Vector2i(-1, -1)
    var clipped := 0
    for y in range(0, image.get_height(), 2):
        for x in range(0, image.get_width(), 2):
            var color := image.get_pixel(x, y)
            var back := background.get_pixel(x, y)
            var difference := absf(color.r - back.r) + absf(color.g - back.g) + absf(color.b - back.b)
            if difference <= 0.06:
                continue
            minimum = minimum.min(Vector2i(x, y))
            maximum = maximum.max(Vector2i(x, y))
            values.append(color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722)
            if color.r > 0.99 and color.g > 0.99 and color.b > 0.99:
                clipped += 1
    values.sort()
    return {
        "samples": values.size(),
        "median_luma": values[values.size() / 2] if not values.is_empty() else 0.0,
        "p90_luma": values[int(values.size() * 0.9)] if not values.is_empty() else 0.0,
        "white_clip_fraction": float(clipped) / maxf(1.0, values.size()),
        "bbox": [minimum.x, minimum.y, maximum.x, maximum.y],
    }

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "A real display/renderer is required")
        quit(1)
        return
    output_dir = OS.get_environment("YARDMAN_GARAGE_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("user://garage-preview-captures")
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Capture directory is unavailable")
    garage = root.get_node("VehicleGarage")
    # Stop unrelated simulation/UI without replacing the production preview.
    for child in root.get_children():
        child.set_process(false)
        child.set_physics_process(false)
    garage.open_garage()
    viewport = garage.get("_preview_viewport")
    (viewport.get_parent() as SubViewportContainer).stretch = false
    viewport.size = Vector2i(720, 480)
    var preview: Node3D = garage.get("_preview_root")
    var environment: Environment
    for child in preview.get_children():
        if child is WorldEnvironment:
            environment = child.environment
    _check(environment != null and environment.sky != null, "Garage has no reflection environment")
    if environment == null:
        quit(1)
        return
    var studio_sky := environment.sky
    _check(studio_sky.radiance_size == Sky.RADIANCE_SIZE_128, "Preview reflection budget changed")
    _check(environment.reflected_light_source == Environment.REFLECTION_SOURCE_SKY, "Solid background disables sky reflections")
    var report := {"engine": Engine.get_version_info(), "method": RenderingServer.get_current_rendering_method(), "adapter": RenderingServer.get_video_adapter_name(), "vehicles": []}
    for vehicle_id in Catalog.production_ids():
        var selector: OptionButton = garage.get("_selector")
        for index in range(selector.item_count):
            if str(selector.get_item_metadata(index)) == str(vehicle_id):
                selector.select(index)
        garage.call("_refresh_preview")
        model = garage.get("_preview_model")
        model.rotation = Vector3(0.0, -0.42, 0.0)
        var stats_before: Dictionary = model.get_meta("yardman_vehicle_visual_stats").duplicate(true)
        var row := {"id": vehicle_id, "asset": model.get("reference_asset_name"), "captures": {}}
        for mode in ["without-reflections", "studio"]:
            environment.sky = studio_sky if mode == "studio" else null
            environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY if mode == "studio" else Environment.AMBIENT_SOURCE_COLOR
            environment.ambient_light_color = Color(0.52, 0.58, 0.66)
            model.hide()
            var background := await _capture()
            model.show()
            var image := await _capture()
            var metrics := _metrics(image, background)
            var filename := "%s-%s.png" % [vehicle_id, mode]
            _check(image.save_png(output_dir.path_join(filename)) == OK, "Could not save preview")
            _check(int(metrics.samples) > 1500, "%s is missing visible geometry" % vehicle_id)
            _check(float(metrics.white_clip_fraction) < 0.10, "%s is overexposed" % vehicle_id)
            var bounds: Array = metrics.bbox
            _check(int(bounds[0]) > 4 and int(bounds[1]) > 4 and int(bounds[2]) < 716 and int(bounds[3]) < 476, "%s preview is cropped" % vehicle_id)
            row.captures[mode] = {"image": filename, "metrics": metrics}
        _check(model.get_meta("yardman_vehicle_visual_stats") == stats_before, "Lighting comparison modified paint/styling")
        if str(vehicle_id) != "toyota_crown":
            _check(float(row.captures.studio.metrics.p90_luma) > float(row.captures["without-reflections"].metrics.p90_luma) + 0.025, "%s metallic highlights have no measurable environment response" % vehicle_id)
        report.vehicles.append(row)
    environment.sky = studio_sky
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    garage.close_garage()
    _check(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Closing garage leaves preview GPU work active")
    report["failures"] = failures
    var file := FileAccess.open(output_dir.path_join("garage-preview-report.json"), FileAccess.WRITE)
    _check(file != null, "Could not save report")
    if file != null:
        file.store_string(JSON.stringify(report, "  ") + "\n")
        file.close()
    print("YARDMAN_GARAGE_PREVIEW_RENDER_TEST %s method=%s captures=6 failures=%d" % ["PASS" if failures == 0 else "FAIL", report.method, failures])
    paused = false
    for child in root.get_children():
        child.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
