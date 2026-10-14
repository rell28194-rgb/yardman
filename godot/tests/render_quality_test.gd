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
    _check(str(vulkan.water_variant) == "depth", "Vulkan Ultra lost its high water variant")
    _check(float(gles.resolution_max) <= 0.82, "GLES Safe exceeds its resolution cap")
    _check(not bool(gles.screen_effects) and str(gles.water_variant) == "opaque", "GLES Safe retained unsupported expensive effects")

    var manager = Manager.new()
    manager.configure("Performance", {}, "vulkan_mobile")
    var start_scale: float = manager.current_scale
    for i in range(180):
        manager.update_frame(1.0 / 30.0, null, true)
    _check(manager.current_scale < start_scale, "Sustained missed frame budget did not reduce internal resolution")
    manager.set_thermal_stage(4)
    var hot := manager.effective_policy()
    _check(float(hot.resolution_max) < float(vulkan.resolution_max), "Thermal stage did not cap resolution")
    _check(str(hot.water_variant) == "opaque" and not bool(hot.screen_effects), "Thermal stage did not move to cheaper material/effect policy")
    print("YARDMAN_RENDER_QUALITY_TEST %s renderer_policy=1 adaptive=1 thermal=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
