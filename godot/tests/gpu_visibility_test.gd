extends SceneTree

const Probe = preload("res://scripts/gpu_visibility_probe.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_VISIBILITY_TEST: " + message)

func _run() -> void:
    var result := Probe.run_probe(8192)
    _check(bool(result.get("supported", false)), "RenderingDevice compute path unavailable: " + str(result.get("reason", "unknown")))
    if bool(result.get("supported", false)):
        _check(int(result.get("count", 0)) == 8192, "compute probe processed wrong instance count")
        _check(int(result.get("mismatches", -1)) == 0, "GPU frustum classification differs from CPU reference")
        _check(int(result.get("visible", 0)) > 0, "compute probe returned no visible instances")
        _check(int(result.get("visible", 0)) < 8192, "compute probe failed to cull any instances")
        print("YARDMAN_GPU_VISIBILITY_METRICS count=%d visible=%d gpu_us=%d cpu_us=%d" % [
            int(result.count), int(result.visible), int(result.gpu_dispatch_us), int(result.cpu_reference_us)])
    print("YARDMAN_GPU_VISIBILITY_TEST %s rd_compute=1 parity=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
