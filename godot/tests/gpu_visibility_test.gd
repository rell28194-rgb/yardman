extends SceneTree

const Probe = preload("res://scripts/gpu_visibility_probe.gd")
const PROBE_COUNTS := [8195, 65537]
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_VISIBILITY_TEST: " + message)

func _run() -> void:
    for probe_count in PROBE_COUNTS:
        var result := Probe.run_probe(probe_count)
        _check(bool(result.get("supported", false)), "RenderingDevice compute path unavailable: " + str(result.get("reason", "unknown")))
        if not bool(result.get("supported", false)):
            continue
        _check(int(result.get("count", 0)) == probe_count, "compute probe processed wrong instance count")
        _check(int(result.get("mismatches", -1)) == 0, "GPU frustum classification differs from CPU reference")
        _check(int(result.get("compact_mismatches", -1)) == 0, "GPU compacted visible-index set differs from CPU reference")
        _check(int(result.get("gpu_visible_count", -1)) == int(result.get("visible", -2)), "GPU atomic visible count differs from CPU reference")
        _check(int(result.get("visible", 0)) > 0, "compute probe returned no visible instances")
        _check(int(result.get("visible", 0)) < probe_count, "compute probe failed to cull any instances")
        _check(int(result.get("gpu_dispatch_us", -1)) >= 0, "missing dispatch timing")
        _check(int(result.get("gpu_readback_us", -1)) >= 0, "missing readback timing")
        print("YARDMAN_GPU_VISIBILITY_METRICS count=%d visible=%d gpu_us=%d readback_us=%d total_us=%d cpu_us=%d compact=1" % [
            int(result.count), int(result.visible), int(result.gpu_dispatch_us), int(result.gpu_readback_us),
            int(result.gpu_total_with_readback_us), int(result.cpu_reference_us)])
    print("YARDMAN_GPU_VISIBILITY_TEST %s rd_compute=1 parity=1 partial_group=1 compact=1 scaling=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
