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
        "yardman_grass_lush.glb": {"height": 0.55, "max_bytes": 2_000_000},
        "yardman_shrub_flowering.glb": {"height": 1.25, "max_bytes": 3_000_000},
        "yardman_shrub_meadow.glb": {"height": 1.05, "max_bytes": 2_000_000},
        "yardman_fern_wet.glb": {"height": 0.95, "max_bytes": 2_000_000},
        "yardman_tree_coastal_a.glb": {"height": 8.2, "max_bytes": 15_000_000},
        "yardman_tree_coastal_b.glb": {"height": 7.5, "max_bytes": 15_000_000},
        "yardman_tree_coastal_c.glb": {"height": 6.8, "max_bytes": 15_000_000},
        "yardman_tree_broadleaf.glb": {"height": 10.5, "max_bytes": 24_000_000},
    }
    var runtime := Runtime.new()
    root.add_child(runtime)
    await process_frame
    var total := 0
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
        total += bytes
        var mesh = runtime.call("_load_runtime_mesh", path, float(expected[filename].height))
        if not mesh is ArrayMesh or mesh.get_surface_count() <= 0:
            _fail("runtime GLB loader failed: " + str(filename))
            return
        var bounds: AABB = mesh.get_aabb()
        if absf(bounds.size.y - float(expected[filename].height)) > 0.08:
            _fail("normalized height failed: %s height=%.3f" % [filename, bounds.size.y])
            return
        mesh = null
    if total != 50_881_392:
        _fail("Environment HD v2 release byte contract changed: %d" % total)
        return
    if total > 96_000_000:
        _fail("Environment HD v2 Android pack budget exceeded: %d" % total)
        return
    print("YARDMAN_ENVIRONMENT_CONTENT_RUNTIME_V2_PASS assets=8 bytes=%d tree_variants=4 shrub_variants=3 grass_variants=1 storage_budget=pass lazy_runtime=enabled" % total)
    quit(0)
