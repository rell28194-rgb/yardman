extends SceneTree

const Manager = preload("res://scripts/render_quality_manager.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RENDER_QUALITY_TEST: " + message)

func _run() -> void:
    var vulkan := Manager.policy_for("Ultra", "vulkan_mobile")
    var gles := Manager.policy_for("Ultra", "gles")
    _check(float(vulkan.resolution_max) >= 0.99, "Vulkan Ultra is not allowed full internal resolution")
    _check(str(vulkan.water_variant) == "depth" and str(vulkan.road_variant) == "high", "Vulkan Ultra lost high material variants")
    _check(float(gles.resolution_max) <= 0.82, "GLES Safe exceeds its resolution cap")
    _check(not bool(gles.screen_effects) and str(gles.water_variant) == "opaque" and str(gles.road_variant) == "safe", "GLES Safe retained expensive material/effect paths")

    var manager = Manager.new()
    manager.configure("Performance", {}, "vulkan_mobile")
    var start_scale: float = manager.current_scale
    for i in range(180):
        manager.update_frame(1.0 / 30.0, null, true)
    _check(manager.current_scale < start_scale, "Sustained missed frame budget did not reduce internal resolution")

    manager.configure("Ultra", {}, "vulkan_mobile")
    manager.set_thermal_stage(3)
    var warm := manager.effective_policy()
    _check(str(warm.road_variant) == "safe", "Thermal stage 3 did not downgrade road shader")
    manager.set_thermal_stage(4)
    var hot := manager.effective_policy()
    _check(float(hot.resolution_max) < float(vulkan.resolution_max), "Thermal stage did not cap resolution")
    _check(str(hot.water_variant) == "opaque" and str(hot.terrain_variant) == "2layer" and not bool(hot.screen_effects), "Thermal stage did not move to cheaper water/terrain/effect policy")
    _check(int(hot.reflection_budget) <= 1, "Hot thermal stage retained expensive reflection budget")

    manager.configure("Performance", {}, "vulkan_mobile")
    manager.set_thermal_stage(5)
    var critical := manager.effective_policy()
    _check(int(critical.target_fps) == 30, "Critical thermal stage did not cap frame pacing to 30 FPS")
    _check(Engine.max_fps == 30, "Engine frame cap did not follow thermal policy")

    manager.configure("Performance", {}, "vulkan_mobile")
    manager.current_scale = float(manager.effective_policy().resolution_min)
    for i in range(260):
        manager.update_frame(1.0 / 20.0, null, true)
    _check(manager.thermal_stage >= 1, "Sustained overload at minimum resolution did not escalate thermal/performance stage")

    print("YARDMAN_RENDER_QUALITY_TEST %s renderer_policy=1 adaptive=1 thermal=1 frame_pacing=1 auto_pressure=1 material_ladder=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
