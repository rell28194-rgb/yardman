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
    var high := Reflections.profile_for(4, "vulkan_mobile")
    _check(bool(low.enabled) and bool(high.enabled), "Vulkan Mobile reflection profiles disabled")
    _check(float(high.extent_m) > float(low.extent_m), "higher reflection budget did not increase capture extent")
    _check(float(high.max_distance_m) > float(low.max_distance_m), "higher reflection budget did not increase capture distance")
    _check(float(high.recapture_m) < float(low.recapture_m), "higher reflection budget did not refresh more frequently")
    _check(float(high.mesh_lod_threshold) < float(low.mesh_lod_threshold), "higher reflection budget did not permit finer reflected LOD")
    _check(float(high.intensity) > float(low.intensity), "higher reflection budget did not increase reflection contribution")

    var off := Reflections.profile_for(0, "vulkan_mobile")
    _check(not bool(off.enabled), "zero reflection budget remained enabled")

    print("YARDMAN_REFLECTION_BUDGET_TEST %s vulkan_levels=4 gles_dynamic=0" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
