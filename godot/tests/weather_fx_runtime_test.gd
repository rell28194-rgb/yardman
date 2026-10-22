extends SceneTree

const Runtime = preload("res://scripts/weather_fx_runtime.gd")
const TerrainShader = preload("res://shaders/terrain_surface.gdshader")
const RoadShader = preload("res://shaders/road_surface.gdshader")
const BeachShader = preload("res://shaders/beach.gdshader")
const BuildingShader = preload("res://shaders/building_surface.gdshader")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String, runtime: Node = null) -> void:
    if runtime != null and is_instance_valid(runtime):
        runtime.queue_free()
    push_error("WEATHER_FX_RUNTIME: " + message)
    await process_frame
    quit(1)

func _run() -> void:
    for parish in ["Kingston", "St. Mary", "Portland", "St. Elizabeth"]:
        for hour in [0.0, 4.5, 9.0, 13.25, 18.0, 23.9, 48.0]:
            var a := Runtime.dynamic_intensity(hour, parish)
            var b := Runtime.dynamic_intensity(hour, parish)
            if not is_finite(a) or a < 0.0 or a > 0.82 or absf(a - b) > 0.000001:
                await _fail("dynamic weather must be finite, bounded and deterministic")
                return

    var runtime := Runtime.new()
    root.add_child(runtime)
    await process_frame
    var state: Dictionary = runtime.debug_state()
    if int(state.rain_batches) != 1 or int(state.max_drops) != 320:
        await _fail("rain batch ceiling changed", runtime)
        return
    if int(state.get("standalone_ui", -1)) != 0 or int(state.get("wettables", 0)) != 4:
        await _fail("weather regained standalone HUD controls or lost wettable families", runtime)
        return
    if not runtime.find_children("*", "Button", true, false).is_empty() \
            or not runtime.find_children("*", "CanvasLayer", true, false).is_empty():
        await _fail("weather engineering controls are still injected into gameplay HUD", runtime)
        return
    var rain = runtime.get("_rain") as MultiMeshInstance3D
    if rain == null or rain.multimesh == null or rain.multimesh.instance_count != 320:
        await _fail("rain MultiMesh allocation contract failed", runtime)
        return
    if rain.multimesh.mesh == null or rain.multimesh.mesh.get_surface_count() != 1:
        await _fail("rain should remain one mesh surface / one batch", runtime)
        return
    if rain.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
        await _fail("rain shadows must stay disabled", runtime)
        return

    runtime.set_mode("Clear")
    if absf(runtime.target_intensity(14.0, "Kingston")) > 0.000001:
        await _fail("Clear mode not zero", runtime)
        return
    runtime.set_mode("Shower")
    if absf(runtime.target_intensity(14.0, "Kingston") - 0.78) > 0.000001:
        await _fail("Shower mode contract changed", runtime)
        return
    runtime.set_mode("Dynamic")
    if runtime.get_mode() != "Dynamic":
        await _fail("weather mode API stopped working after HUD removal", runtime)
        return

    var camera := Camera3D.new()
    root.add_child(camera)
    runtime.set("_intensity", 0.78)
    runtime.call("_update_rain", camera, "Balanced", false)
    if rain.multimesh.visible_instance_count <= 0 or rain.multimesh.visible_instance_count > 150:
        await _fail("Balanced rain visibility cap failed", runtime)
        return
    runtime.call("_update_rain", camera, "Ultra", false)
    if rain.multimesh.visible_instance_count > 300:
        await _fail("Ultra rain visibility cap failed", runtime)
        return
    runtime.call("_update_rain", camera, "Ultra", true)
    if rain.multimesh.visible_instance_count > 165:
        await _fail("Reduced Motion rain cap failed", runtime)
        return

    var terrain := ShaderMaterial.new()
    terrain.shader = TerrainShader
    var road := ShaderMaterial.new()
    road.shader = RoadShader
    var beach := ShaderMaterial.new()
    beach.shader = BeachShader
    var building := ShaderMaterial.new()
    building.shader = BuildingShader
    runtime.call("_track_material", terrain)
    runtime.call("_track_material", road)
    runtime.call("_track_material", beach)
    runtime.call("_track_material", building)
    runtime.set("_intensity", 0.63)
    runtime.call("_apply_wetness")
    for material in [terrain, road, beach, building]:
        if absf(float(material.get_shader_parameter("weather_wetness")) - 0.63) > 0.0001:
            await _fail("wetness binding failed", runtime)
            return
    var building_code := BuildingShader.code
    if not building_code.contains("weather_wetness") or not building_code.contains("wet_darkening") \
            or not building_code.contains("wet_roughness"):
        await _fail("building wetness shader contract is incomplete", runtime)
        return

    print("YARDMAN_WEATHER_FX_RUNTIME_PASS rain_batches=1 max_drops=320 balanced_cap=150 ultra_cap=300 reduced_motion_cap=165 wetness_materials=4 standalone_ui=0 dynamic=deterministic")

    terrain.shader = null
    road.shader = null
    beach.shader = null
    building.shader = null
    terrain = null
    road = null
    beach = null
    building = null
    camera.queue_free()
    runtime.queue_free()
    for _frame in range(4):
        await process_frame
    quit(0)
