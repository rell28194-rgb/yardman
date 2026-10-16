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
    _check(Manager.paced_fps(45, 60.0) == 30, "60 Hz display retained uneven 45 FPS cadence")
    _check(Manager.paced_fps(45, 90.0) == 45, "90 Hz display lost 45 FPS cadence")
    _check(Manager.paced_fps(45, 120.0) == 40, "120 Hz display retained uneven 45 FPS cadence")
    _check(Manager.paced_fps(60, 59.94) == 60, "Fractional 60 Hz refresh was not tolerated")
    _check(Manager.paced_fps(60, -1.0) == 60, "Unavailable refresh rate did not use 60 Hz fallback")
    _check(Manager.paced_fps(30, 144.0) == 24, "144 Hz display retained uneven 30 FPS cadence")
    var corrupt := Manager.policy_for("Custom", "gles", {"target_fps": NAN, "resolution_min": -5.0, "resolution_max": INF, "resolution_default": "invalid", "shadow_distance": -100.0, "road_visibility": 90000.0})
    _check(int(corrupt.target_fps) == 30 and float(corrupt.resolution_min) >= 0.5 and float(corrupt.resolution_max) <= 0.82, "Corrupt custom settings escaped safe resolution/FPS bounds")
    _check(float(corrupt.shadow_distance) == 10.0 and float(corrupt.road_visibility) <= 2200.0, "Corrupt custom settings escaped world budgets")

    var manager = Manager.new()
    manager.configure("Performance", {}, "vulkan_mobile")
    var start_scale: float = manager.current_scale
    for i in range(180):
        manager.update_frame(1.0 / 30.0, null, true)
    _check(manager.current_scale < start_scale, "Sustained missed frame budget did not reduce internal resolution")
    manager.configure("Performance", {}, "vulkan_mobile", 60.0)
    manager.set_thermal_stage(0)
    manager.auto_thermal_enabled = false
    manager.current_scale = 0.60
    for i in range(900):
        manager.update_frame(1.0 / 60.0, null, true, 5.0)
    _check(manager.current_scale > 0.60, "Capped stable frames with measured GPU headroom could not recover resolution")
    _check(bool(manager.timing_snapshot().gpu_timing_available), "Valid GPU timings were not exposed")
    manager.configure("Performance", {}, "vulkan_mobile", 60.0)
    manager.current_scale = 0.60
    for i in range(900):
        manager.update_frame(1.0 / 60.0, null, true)
    _check(is_equal_approx(manager.current_scale, 0.60), "Missing GPU timings fabricated headroom from capped frames")
    _check(not bool(manager.timing_snapshot().gpu_timing_available), "Unavailable GPU timing was reported as measured")
    var before_pause: float = manager.current_scale
    manager.update_frame(15.0, null, true, 2000.0)
    manager.update_frame(NAN, null, true)
    _check(is_equal_approx(manager.current_scale, before_pause) and manager.thermal_stage == 0, "Resume/loading gap caused a quality or thermal downgrade")
    manager.configure("Balanced", {}, "vulkan_mobile", 90.0)
    _check(Engine.max_fps == 45, "Engine cap ignored 90 Hz cadence")
    manager.set_refresh_rate(120.0)
    _check(Engine.max_fps == 40, "Display refresh change did not repace frame delivery")

    manager.configure("Ultra", {}, "vulkan_mobile")
    manager.set_thermal_stage(3)
    var warm := manager.effective_policy()
    _check(str(warm.road_variant) == "safe", "Thermal stage 3 did not downgrade road shader")
    manager.set_thermal_stage(4)
    var hot := manager.effective_policy()
    _check(float(hot.resolution_max) < float(vulkan.resolution_max), "Thermal stage did not cap resolution")
    _check(str(hot.water_variant) == "opaque" and str(hot.terrain_variant) == "2layer" and not bool(hot.screen_effects), "Thermal stage did not move to cheaper water/terrain/effect policy")
    _check(int(hot.reflection_budget) <= 1, "Hot thermal stage retained expensive reflection budget")
    manager.configure("Performance", {}, "vulkan_mobile", 60.0)
    _check(manager.thermal_stage == 4 and Engine.max_fps == 60, "Quality switch cleared pressure or frame rate degraded before the final thermal stage")

    manager.configure("Performance", {}, "vulkan_mobile")
    manager.set_thermal_stage(0)
    manager.auto_thermal_enabled = true
    manager.set_thermal_stage(5)
    var critical := manager.effective_policy()
    _check(int(critical.target_fps) == 30, "Critical thermal stage did not cap frame pacing to 30 FPS")
    _check(Engine.max_fps == 30, "Engine frame cap did not follow thermal policy")

    manager.configure("Performance", {}, "vulkan_mobile")
    manager.current_scale = float(manager.effective_policy().resolution_min)
    for i in range(260):
        manager.update_frame(1.0 / 20.0, null, true)
    _check(manager.thermal_stage >= 1, "Sustained overload at minimum resolution did not escalate thermal/performance stage")
    manager.set_thermal_stage(2)
    manager.reset_frame_history()
    for i in range(2400):
        manager.update_frame(1.0 / 60.0, null, true, 4.0)
    _check(manager.thermal_stage < 2, "Measured GPU headroom under frame cap could not recover thermal/performance stage")

    print("YARDMAN_RENDER_QUALITY_TEST %s renderer_policy=1 adaptive=1 thermal=1 frame_pacing=1 auto_pressure=1 material_ladder=1 refresh_cadence=1 gpu_headroom=1 invalid_preferences=1 resume=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
