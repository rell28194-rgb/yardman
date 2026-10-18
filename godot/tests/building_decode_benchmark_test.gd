extends SceneTree

const BuildingScript = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_DECODE_BENCH: " + message)

func _record(index: int) -> Array:
    var x := float(index % 32) * 18.0
    var z := float(index / 32) * 18.0
    var height := 6.0 + float(index % 7) * 1.8
    return ["bench:%d" % index, 4.0, 2, 0, height,
        [[[x, 2.0, z], [x + 12.0, 2.0, z], [x + 12.0, 2.0, z + 10.0], [x, 2.0, z + 10.0]]],
        [[x, z], [x + 12.0, z], [x + 12.0, z + 10.0], [x, z + 10.0]],
        [0, 2, 1, 0, 3, 2]]

func _write_pack(path: String, count: int) -> Dictionary:
    var records: Array = []
    records.resize(count)
    for index in range(count):
        records[index] = _record(index)
    var json := JSON.stringify(records).to_utf8_buffer()
    var compressed := json.compress(FileAccess.COMPRESSION_GZIP)
    var file := FileAccess.open(path, FileAccess.WRITE)
    _check(file != null, "Could not create synthetic YMB1 pack")
    if file == null:
        return {}
    file.store_buffer("YMB1".to_ascii_buffer())
    file.store_32(1)
    file.store_16(0)
    file.store_16(0)
    file.store_32(20)
    file.store_32(compressed.size())
    file.store_buffer(compressed)
    file.close()
    return {
        "records": count,
        "json_bytes": json.size(),
        "compressed_bytes": compressed.size(),
    }

func _median(values: Array[int]) -> int:
    var copy := values.duplicate()
    copy.sort()
    return int(copy[copy.size() / 2])

func _measure(path: String, expected_count: int, iterations: int = 12) -> Dictionary:
    var warmup: Dictionary = BuildingScript._read_cell(path, Vector2i.ZERO)
    _check(not warmup.has("error"), "Warmup decode failed: " + str(warmup.get("error", "unknown")))
    _check(warmup.get("records", []).size() == expected_count, "Warmup record count mismatch")
    var samples: Array[int] = []
    for _iteration in range(iterations):
        var started := Time.get_ticks_usec()
        var decoded: Dictionary = BuildingScript._read_cell(path, Vector2i.ZERO)
        var elapsed := Time.get_ticks_usec() - started
        _check(not decoded.has("error"), "Timed decode failed: " + str(decoded.get("error", "unknown")))
        _check(decoded.get("records", []).size() == expected_count, "Timed record count mismatch")
        samples.append(elapsed)
    var total := 0
    var minimum := 1 << 30
    var maximum := 0
    for sample in samples:
        total += sample
        minimum = mini(minimum, sample)
        maximum = maxi(maximum, sample)
    return {
        "median_us": _median(samples),
        "mean_us": int(round(float(total) / float(samples.size()))),
        "min_us": minimum,
        "max_us": maximum,
    }

func _run() -> void:
    var root_path := "user://yardman/tests/building_decode_bench"
    DirAccess.make_dir_recursive_absolute(root_path)
    var cases := [
        {"name": "small", "count": 16},
        {"name": "medium", "count": 128},
        {"name": "dense", "count": 512},
    ]
    var evidence: Dictionary = {}
    for case_value in cases:
        var case: Dictionary = case_value
        var name := str(case.name)
        var path := "%s/%s.ymb" % [root_path, name]
        var pack := _write_pack(path, int(case.count))
        var timing := _measure(path, int(case.count))
        evidence[name] = {
            "records": int(case.count),
            "json_bytes": int(pack.get("json_bytes", 0)),
            "compressed_bytes": int(pack.get("compressed_bytes", 0)),
            "median_us": int(timing.get("median_us", 0)),
            "mean_us": int(timing.get("mean_us", 0)),
            "min_us": int(timing.get("min_us", 0)),
            "max_us": int(timing.get("max_us", 0)),
        }
        _check(int(evidence[name].compressed_bytes) > 0, name + " pack compressed to zero bytes")
        _check(int(evidence[name].json_bytes) > int(evidence[name].compressed_bytes), name + " fixture did not exercise gzip compression")
        _check(int(evidence[name].median_us) > 0, name + " timing was not captured")

    _check(int(evidence.small.records) < int(evidence.medium.records) and int(evidence.medium.records) < int(evidence.dense.records), "Benchmark density ladder is invalid")
    if failures == 0:
        print("YARDMAN_BUILDING_DECODE_BENCH PASS evidence=" + JSON.stringify(evidence))
    quit(0 if failures == 0 else 1)
