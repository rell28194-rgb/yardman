extends SceneTree

const Capabilities = preload("res://scripts/gpu_driven_capabilities.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_DRIVEN_CAPABILITIES_TEST: " + message)

func _run() -> void:
    var result := Capabilities.snapshot()
    var method := str(result.rendering_method)
    var driver := str(result.rendering_driver)
    _check(bool(result.fallback_required) != bool(result.gpu_driven_candidate), "candidate/fallback states are not complementary")
    _check(bool(result.indirect_api_available), "required RenderingServer indirect APIs are absent: " + str(result.missing_apis))

    if method == "mobile" and driver == "vulkan":
        _check(bool(result.rendering_device_available), "Vulkan Mobile has no global RenderingDevice")
        _check(bool(result.gpu_driven_candidate), "validated Vulkan Mobile path failed closed unexpectedly")
        _check(not bool(result.fallback_required), "Vulkan Mobile candidate incorrectly requires fallback")
    else:
        _check(not bool(result.gpu_driven_candidate), "unsupported renderer incorrectly enabled GPU-driven path")
        _check(bool(result.fallback_required), "unsupported renderer did not require fallback")
        _check(not str(result.fallback_reason).is_empty(), "fallback has no explicit reason")

    print("YARDMAN_GPU_DRIVEN_CAPABILITIES method=%s driver=%s candidate=%d fallback=%d reason=%s" % [
        method, driver, int(bool(result.gpu_driven_candidate)), int(bool(result.fallback_required)), str(result.fallback_reason)])
    print("YARDMAN_GPU_DRIVEN_CAPABILITIES_TEST %s fail_closed=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
