extends SceneTree

const Runtime = preload("res://scripts/environment_content_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("ENVIRONMENT_CONTENT_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var root_path := "res://build/environment-runtime-test/"
    var expected := {
        "yardman_grass_cluster.glb": {"height": 0.55, "max_bytes": 2_000_000},
        "yardman_shrub_near.glb": {"height": 1.15, "max_bytes": 2_000_000},
        "yardman_island_tree_near.glb": {"height": 8.2, "max_bytes": 15_000_000},
    }
    var runtime := Runtime.new()
    root.add_child(runtime)
    await process_frame
    for filename in expected.keys():
        var path: String = root_path + str(filename)
        if not FileAccess.file_exists(path):
            _fail("missing downloaded test asset: " + path)
            return
        var handle := FileAccess.open(path, FileAccess.READ)
        var bytes: int = int(handle.get_length()) if handle != null else -1
        if bytes <= 0 or bytes > int(expected[filename].max_bytes):
            _fail("asset byte budget failed: %s bytes=%d" % [filename, bytes])
            return
        var mesh = runtime.call("_load_runtime_mesh", path, float(expected[filename].height))
        if not mesh is ArrayMesh or mesh.get_surface_count() <= 0:
            _fail("runtime GLB loader failed: " + str(filename))
            return
        var bounds: AABB = mesh.get_aabb()
        if absf(bounds.size.y - float(expected[filename].height)) > 0.06:
            _fail("normalized height failed: %s height=%.3f" % [filename, bounds.size.y])
            return
    var total := 0
    for filename in expected.keys():
        var file := FileAccess.open(root_path + str(filename), FileAccess.READ)
        total += int(file.get_length()) if file != null else 0
    if total > 20_000_000:
        _fail("Environment HD v1 transfer budget exceeded: %d" % total)
        return
    print("YARDMAN_ENVIRONMENT_CONTENT_RUNTIME_PASS assets=3 bytes=%d roles=grass_near,shrub_near,tree_near fallback=embedded multimesh=bounded" % total)
    quit(0)
