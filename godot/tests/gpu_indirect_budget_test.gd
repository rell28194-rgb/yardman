extends SceneTree

const Budget = preload("res://scripts/gpu_indirect_budget.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_INDIRECT_BUDGET_TEST: " + message)

func _run() -> void:
    _check(Budget.MULTIMESH_RECORD_BYTES == 80,
        "Transform3D+color+custom MultiMesh record is no longer 80 bytes")
    _check(Budget.PACKED_ROADSIDE_SOURCE_BYTES == 32,
        "packed roadside source exceeded two vec4 records")
    _check(Budget.square_tile_count(3) == 49,
        "Ultra road radius no longer resolves to 49 wanted tiles")
    _check(Budget.square_tile_count(4) == 81,
        "road retention margin no longer resolves to 81 possible resident tiles")

    var baseline_per_anchor := Budget.destination_bytes(1, 1)
    var naive_per_anchor := Budget.naive_generic_total_bytes(1, 1)
    var shared_full_per_anchor := Budget.shared_full_source_total_bytes(1, 1)
    var packed_per_anchor := Budget.packed_source_total_bytes(1, 1)
    _check(baseline_per_anchor == 240,
        "three roadside destination layers no longer cost 240 bytes per anchor")
    _check(naive_per_anchor == 528,
        "naive per-layer generic source estimate changed unexpectedly")
    _check(shared_full_per_anchor == 336,
        "shared full-record source estimate changed unexpectedly")
    _check(packed_per_anchor == 272,
        "packed source estimate changed unexpectedly")

    var wanted := Budget.production_plan(3, false)
    var resident := Budget.production_plan(3, true)
    _check(int(wanted.tiles) == 49 and int(wanted.anchors) == 88200,
        "wanted-tile worst-case anchor count is incorrect")
    _check(int(resident.tiles) == 81 and int(resident.anchors) == 145800,
        "retained-tile worst-case anchor count is incorrect")
    _check(is_equal_approx(float(wanted.naive_overhead), 1.20),
        "naive generic path should be rejected at 120% memory overhead")
    _check(is_equal_approx(float(wanted.shared_full_overhead), 0.40),
        "shared full-record path should still cost 40% overhead")
    _check(float(wanted.packed_overhead) < 0.14,
        "packed roadside source exceeded the ~13.3% overhead target")
    _check(bool(wanted.packed_contract_ok) and bool(resident.packed_contract_ok),
        "packed production contract fails at max wanted/retained radius")

    print("YARDMAN_GPU_INDIRECT_BUDGET_METRICS wanted_tiles=%d retained_tiles=%d baseline_mb=%.2f naive_mb=%.2f packed_mb=%.2f packed_overhead=%.4f" % [
        int(wanted.tiles), int(resident.tiles), float(wanted.baseline_bytes) / 1048576.0,
        float(wanted.naive_bytes) / 1048576.0, float(wanted.packed_bytes) / 1048576.0,
        float(wanted.packed_overhead)])
    print("YARDMAN_GPU_INDIRECT_BUDGET_TEST %s full_source_rejected=1 packed_source_required=1 max_radius=1 retention_margin=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
