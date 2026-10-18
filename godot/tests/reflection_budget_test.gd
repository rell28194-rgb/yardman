extends SceneTree

const Reflections = preload("res://scripts/reflection_budget_runtime.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("REFLECTION_BUDGET_TEST: " + message)

func _run() -> void:
    var gles := Reflections.profile_for(4, "gles")
    _check(not bool(gles.enabled), "GLES fallback enabled moving reflection probes")

    var low := Reflections.profile_for(1, "vulkan_mobile")
    var medium := Reflections.profile_for(2, "vulkan_mobile")
    var quality := Reflections.profile_for(3, "vulkan_mobile")
    var high := Reflections.profile_for(4, "vulkan_mobile")
    _check(bool(low.enabled) and bool(high.enabled), "Vulkan Mobile reflection profiles disabled")
    _check(float(high.extent_m) > float(low.extent_m), "higher reflection budget did not increase capture extent")
    _check(float(high.max_distance_m) > float(low.max_distance_m), "higher reflection budget did not increase capture distance")
    _check(float(high.recapture_m) < float(low.recapture_m), "higher reflection budget did not refresh more frequently")
    _check(float(high.mesh_lod_threshold) < float(low.mesh_lod_threshold), "higher reflection budget did not permit finer reflected LOD")
    _check(float(high.intensity) > float(low.intensity), "higher reflection budget did not increase reflection contribution")
    _check(float(low.min_interval_s) > float(medium.min_interval_s), "reflection time gate did not scale with budget")
    _check(float(medium.min_interval_s) > float(quality.min_interval_s), "quality reflection cadence ordering regressed")
    _check(float(quality.min_interval_s) > float(high.min_interval_s), "Ultra reflection cadence ordering regressed")
    _check(float(high.min_interval_s) >= 0.25, "Ultra reflection probe can recapture too frequently")

    _check(Reflections.capture_due(true, 0.0, 0.0, high), "first reflection capture is not immediate")
    _check(not Reflections.capture_due(false, float(high.recapture_m) + 50.0, float(high.min_interval_s) * 0.5, high), "distance bypassed reflection time gate")
    _check(not Reflections.capture_due(false, float(high.recapture_m) * 0.5, float(high.min_interval_s) + 5.0, high), "time bypassed reflection distance gate")
    _check(Reflections.capture_due(false, float(high.recapture_m), float(high.min_interval_s), high), "valid reflection recapture was rejected")
    _check(not Reflections.capture_due(false, NAN, 1.0, high), "invalid movement produced a reflection capture")
    _check(not Reflections.capture_due(false, 10.0, NAN, high), "invalid elapsed time produced a reflection capture")

    var off := Reflections.profile_for(0, "vulkan_mobile")
    _check(not bool(off.enabled), "zero reflection budget remained enabled")

    print("YARDMAN_REFLECTION_BUDGET_TEST %s vulkan_levels=4 gles_dynamic=0 distance_gate=1 time_gate=1 invalid_inputs=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
