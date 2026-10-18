extends SceneTree

const BuildingScript = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_DECODE_FIXTURE: " + message)

func _record(index: int) -> Array:
    var x := float(index % 32) * 18.0
    var z := float(index / 32) * 18.0
    var height := 6.0 + float(index % 7) * 1.8
    return ["fixture:%d" % index, 4.0, 2, 0, height,
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
    _check(file != null, "Could not create isolated decoder fixture")
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
    return {"records": count, "json_bytes": json.size(), "compressed_bytes": compressed.size()}

func _run() -> void:
    var root_path := "user://yardman/tests/building_decode_fixture"
    DirAccess.make_dir_recursive_absolute(root_path)
    var cases := [16, 128, 512]
    for count in cases:
        var path := "%s/%d.ymb" % [root_path, count]
        var pack := _write_pack(path, count)
        var decoded: Dictionary = BuildingScript._read_cell(path, Vector2i.ZERO)
        _check(not decoded.has("error"), "Fixture decode failed: " + str(decoded.get("error", "unknown")))
        _check(decoded.get("records", []).size() == count, "Fixture record count mismatch")
        _check(int(pack.get("compressed_bytes", 0)) > 0, "Fixture compressed to zero bytes")
        _check(int(pack.get("json_bytes", 0)) > int(pack.get("compressed_bytes", 0)), "Fixture did not exercise gzip")
    if failures == 0:
        print("YARDMAN_BUILDING_DECODE_FIXTURE_TEST PASS synthetic_only=1 production_evidence=0")
    quit(0 if failures == 0 else 1)
