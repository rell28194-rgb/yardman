extends SceneTree

const CoordinatesScript = preload("res://scripts/world_coordinates.gd")
const BuildingScript = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_STREAMER_TEST: " + message)

func _record(identifier: String) -> Array:
    return [identifier, 4.4, 3, 0, 9.4,
        [[[0, 5, 0], [20, 5, 0], [20, 5, 20], [0, 5, 20]]],
        [[0, 0], [20, 0], [20, 20], [0, 20]], [0, 2, 1, 0, 3, 2]]

func _write_pack(path: String, identifier: String) -> void:
    var bytes := JSON.stringify([_record(identifier)]).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_buffer("YMB1".to_ascii_buffer())
    file.store_32(1)
    file.store_16(0)
    file.store_16(0)
    file.store_32(20)
    file.store_32(bytes.size())
    file.store_buffer(bytes)
    file.close()

func _wait_idle(streamer) -> void:
    for frame in range(600):
        await process_frame
        if streamer.is_idle():
            return
    _check(false, "Streamer did not finish bounded synthetic cell jobs")

func _run() -> void:
    var root_path := "user://yardman/tests/buildings"
    DirAccess.make_dir_recursive_absolute(root_path)
    _write_pack(root_path + "/zero.ymb", "w42:0")
    _write_pack(root_path + "/far.ymb", "w99:0")
    var manifest := {"format": 1, "crs": "EPSG:3448", "origin": {"easting": 100000.0, "northing": 200000.0}, "tile_size": 4096, "cell_size": 256,
        "stats": {"buildings": 2, "cells": 2}, "tiles": [
            {"x": 0, "z": 0, "file": "zero.ymb", "cells": [[0, 0]]},
            {"x": 10, "z": 0, "file": "far.ymb", "cells": [[0, 0]]}]}
    var file := FileAccess.open(root_path + "/manifest.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(manifest))
    file.close()
    var coordinates = CoordinatesScript.new()
    coordinates.configure(manifest)
    var streamer = BuildingScript.new()
    streamer.configure(root_path, coordinates)
    root.add_child(streamer)
    streamer.update_world(10.0, 10.0, true)
    await _wait_idle(streamer)
    _check(streamer._loaded.size() == 1 and streamer._loaded.has("0:0"), "Near real cell did not load")
    _check(streamer.inflight_count() == 0, "In-flight count remained nonzero after cells completed")
    if streamer._loaded.has("0:0"):
        var entry: Dictionary = streamer._loaded["0:0"]
        _check(entry.count == 1 and entry.root.get_node("Walls").mesh.get_surface_count() == 1 and entry.root.get_node("Roofs").mesh.get_surface_count() == 1, "Cell did not produce merged wall and roof meshes")
        _check(entry.body.collision_layer == 1, "Nearby building collision was not active")
        streamer.update_world(760.0, 10.0, true)
        await _wait_idle(streamer)
        _check(entry.body.collision_layer == 0 and entry.collider.shape == null, "Distant visible building retained a physics BVH")
        streamer.update_world(10.0, 10.0, true)
        await _wait_idle(streamer)
        _check(entry.body.collision_layer == 1 and entry.collider.shape != null, "Approaching a cell did not restore near collision")
        var before: Vector3 = entry.root.position
        var shift: Vector3 = coordinates.rebase(1000.25, 2000.5)
        streamer.rebase_by(shift)
        _check(entry.root.position.is_equal_approx(before + shift), "Origin rebase did not shift building roots exactly once")
        var world: PackedFloat64Array = coordinates.local_to_world(entry.root.position)
        _check(absf(world[0]) < 0.001 and absf(world[2]) < 0.001, "Building origin changed canonical coordinates")
    streamer.update_world(40970.0, 10.0, true)
    await _wait_idle(streamer)
    _check(streamer._loaded.size() == 1 and streamer._loaded.has("160:0"), "Far warp did not cancel/unload old content")
    _check(streamer._jobs.size() <= streamer.max_io_jobs and streamer._loaded.size() <= streamer.max_loaded_cells, "Streamer resource bounds were exceeded")
    var address: Dictionary = streamer._address(Vector2i(-1, -17))
    _check(address.tile == Vector2i(-1, -2) and address.local == Vector2i(15, 15), "Negative cell addressing truncates instead of flooring")
    var broken := FileAccess.open(root_path + "/broken.ymb", FileAccess.WRITE)
    broken.store_buffer("YMB1".to_ascii_buffer())
    broken.store_32(1)
    broken.store_16(0)
    broken.store_16(0)
    broken.store_32(0)
    broken.store_32(99)
    broken.close()
    _check(BuildingScript._read_cell(root_path + "/broken.ymb", Vector2i.ZERO).has("error"), "Malformed pack index was accepted")
    streamer.quality = "Performance"
    _check(streamer.draw_distance == 450.0 and streamer.max_loaded_cells == 64, "Graphics quality did not bound building visibility/residency")
    print("YARDMAN_BUILDING_STREAMER_TEST %s cells=1 meshes=1 collision=1 cancel=1 rebase=1 bounds=1 corruption=1" % ("PASS" if failures == 0 else "FAIL"))
    streamer.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
