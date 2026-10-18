extends SceneTree

const Probe = preload("res://scripts/gpu_hzb_probe.gd")
const WIDTH := 128
const HEIGHT := 72
const CANDIDATES := 4096
const STRIDE := 5
const DEPTH_BIAS_M := 0.05

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_HZB_TEST: " + message)

func _run() -> void:
    var result := Probe.run_probe(WIDTH, HEIGHT, CANDIDATES)
    _check(bool(result.get("supported", false)),
        "HZB compute path unavailable: " + str(result.get("reason", "unknown")))
    if not bool(result.get("supported", false)):
        quit(1)
        return

    var depth: PackedFloat32Array = result.base_depth
    var pyramid: PackedFloat32Array = result.pyramid
    var candidates: PackedFloat32Array = result.candidates
    var visibility: PackedInt32Array = result.visibility
    var levels: Array = result.levels
    _check(depth.size() == WIDTH * HEIGHT, "base depth size changed")
    _check(candidates.size() == CANDIDATES * STRIDE, "candidate buffer size changed")
    _check(visibility.size() == CANDIDATES, "visibility output size changed")
    _check(levels.size() >= 7, "depth pyramid has too few levels")

    var cpu_pyramid := _build_cpu_pyramid(depth, levels)
    _check(cpu_pyramid.size() == pyramid.size(), "GPU pyramid size differs from CPU reference")
    var pyramid_mismatches := 0
    for index in range(mini(cpu_pyramid.size(), pyramid.size())):
        if absf(cpu_pyramid[index] - pyramid[index]) > 0.0001:
            pyramid_mismatches += 1
    _check(pyramid_mismatches == 0, "GPU max-depth pyramid differs from independent CPU reduction")

    var gpu_cpu_mismatches := 0
    var false_occlusions := 0
    var truth_occluded := 0
    var gpu_occluded := 0
    var conservative_misses := 0
    for index in range(CANDIDATES):
        var gpu_visible := visibility[index] != 0
        var cpu_hzb_visible := _cpu_hzb_visible(index, candidates, cpu_pyramid, levels)
        if gpu_visible != cpu_hzb_visible:
            gpu_cpu_mismatches += 1
        var brute_occluded := _brute_force_occluded(index, candidates, depth)
        if brute_occluded:
            truth_occluded += 1
        if not gpu_visible:
            gpu_occluded += 1
            if not brute_occluded:
                false_occlusions += 1
        elif brute_occluded:
            conservative_misses += 1

    var efficiency := float(gpu_occluded) / float(maxi(truth_occluded, 1))
    _check(gpu_cpu_mismatches == 0,
        "GPU HZB decisions differ from independent CPU HZB implementation")
    _check(false_occlusions == 0,
        "conservative HZB produced a visible-object false occlusion")
    _check(truth_occluded >= 700,
        "test depth field did not generate enough truly occluded candidates")
    _check(gpu_occluded > 0, "HZB failed to reject any candidates")
    _check(efficiency >= 0.45,
        "conservative HZB rejected too few safely occluded candidates")
    _check(int(result.pyramid_bytes) <= WIDTH * HEIGHT * 6,
        "HZB pyramid exceeded 1.5x base-depth memory budget")

    print("YARDMAN_GPU_HZB_METRICS candidates=%d truth_occluded=%d gpu_occluded=%d misses=%d false_occlusions=%d parity_mismatches=%d efficiency=%.4f pyramid_bytes=%d roundtrip_us=%d" % [
        CANDIDATES, truth_occluded, gpu_occluded, conservative_misses,
        false_occlusions, gpu_cpu_mismatches, efficiency,
        int(result.pyramid_bytes), int(result.roundtrip_us)])
    print("YARDMAN_GPU_HZB_TEST %s conservative=1 cpu_parity=1 max_reduce=1 memory_bound=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _build_cpu_pyramid(base_depth: PackedFloat32Array, levels: Array) -> PackedFloat32Array:
    var total := 0
    for level: Vector3i in levels:
        total += level.y * level.z
    var result := PackedFloat32Array()
    result.resize(total)
    result.fill(Probe.FAR_DEPTH_M)
    for index in range(base_depth.size()):
        result[index] = base_depth[index]
    for level_index in range(1, levels.size()):
        var src: Vector3i = levels[level_index - 1]
        var dst: Vector3i = levels[level_index]
        for y in range(dst.z):
            for x in range(dst.y):
                var maximum_depth := 0.0
                for oy in range(2):
                    var source_y := mini(y * 2 + oy, src.z - 1)
                    for ox in range(2):
                        var source_x := mini(x * 2 + ox, src.y - 1)
                        maximum_depth = maxf(maximum_depth,
                            result[src.x + source_y * src.y + source_x])
                result[dst.x + y * dst.y + x] = maximum_depth
    return result

func _cpu_hzb_visible(index: int, candidates: PackedFloat32Array,
        pyramid: PackedFloat32Array, levels: Array) -> bool:
    var base := index * STRIDE
    var min_x := float(candidates[base + 0])
    var min_y := float(candidates[base + 1])
    var max_x := float(candidates[base + 2])
    var max_y := float(candidates[base + 3])
    var near_depth := float(candidates[base + 4])
    if near_depth <= 0.0 or max_x < 0.0 or max_y < 0.0 or min_x >= WIDTH or min_y >= HEIGHT:
        return true
    min_x = clampf(min_x, 0.0, WIDTH - 1.0)
    min_y = clampf(min_y, 0.0, HEIGHT - 1.0)
    max_x = clampf(max_x, 0.0, WIDTH - 1.0)
    max_y = clampf(max_y, 0.0, HEIGHT - 1.0)

    var chosen: Vector3i = levels[levels.size() - 1]
    var x0 := 0
    var y0 := 0
    var x1 := 0
    var y1 := 0
    for level: Vector3i in levels:
        var scale_x := float(WIDTH) / float(level.y)
        var scale_y := float(HEIGHT) / float(level.z)
        var candidate_x0 := mini(floori(min_x / scale_x), level.y - 1)
        var candidate_y0 := mini(floori(min_y / scale_y), level.z - 1)
        var candidate_x1 := mini(floori(max_x / scale_x), level.y - 1)
        var candidate_y1 := mini(floori(max_y / scale_y), level.z - 1)
        if candidate_x1 - candidate_x0 <= 1 and candidate_y1 - candidate_y0 <= 1:
            chosen = level
            x0 = candidate_x0
            y0 = candidate_y0
            x1 = candidate_x1
            y1 = candidate_y1
            break
    var maximum_depth := 0.0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            maximum_depth = maxf(maximum_depth, pyramid[chosen.x + y * chosen.y + x])
    return not (maximum_depth + DEPTH_BIAS_M < near_depth)

func _brute_force_occluded(index: int, candidates: PackedFloat32Array,
        depth: PackedFloat32Array) -> bool:
    var base := index * STRIDE
    var min_x := float(candidates[base + 0])
    var min_y := float(candidates[base + 1])
    var max_x := float(candidates[base + 2])
    var max_y := float(candidates[base + 3])
    var near_depth := float(candidates[base + 4])
    if near_depth <= 0.0 or max_x < 0.0 or max_y < 0.0 or min_x >= WIDTH or min_y >= HEIGHT:
        return false
    var x0 := clampi(floori(min_x), 0, WIDTH - 1)
    var y0 := clampi(floori(min_y), 0, HEIGHT - 1)
    var x1 := clampi(floori(max_x), 0, WIDTH - 1)
    var y1 := clampi(floori(max_y), 0, HEIGHT - 1)
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if depth[y * WIDTH + x] + DEPTH_BIAS_M >= near_depth:
                return false
    return true
