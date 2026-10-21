extends SceneTree

const DetailRuntime = preload("res://scripts/world_detail_runtime.gd")
const WaterRuntime = preload("res://scripts/stream_water_runtime.gd")
const References = preload("res://scripts/reference_assets.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("STREAMED_CONTENT_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var detail = DetailRuntime.new()
    var seed_a := int(detail.call("_seed", Vector2i(12, -8), 41, 17))
    var seed_b := int(detail.call("_seed", Vector2i(12, -8), 41, 17))
    var seed_c := int(detail.call("_seed", Vector2i(12, -8), 42, 17))
    if seed_a != seed_b or seed_a == seed_c:
        detail.free()
        _fail("deterministic vegetation seed contract failed")
        return
    var grass = detail.call("_grass_mesh")
    if not grass is ArrayMesh or grass.get_surface_count() != 1:
        detail.free()
        _fail("grass MultiMesh source geometry missing")
        return
    for quality in ["Performance", "Balanced", "Quality", "Ultra"]:
        var profile: Dictionary = DetailRuntime.PROFILES[quality]
        if int(profile.radius) < 1 or int(profile.radius) > 3:
            detail.free()
            _fail("detail radius outside Android budget for " + quality)
            return
        if int(profile.samples) > 500:
            detail.free()
            _fail("detail sample budget too high for " + quality)
            return
    detail.free()

    var water = WaterRuntime.new()
    water.call("_make_material")
    var material = water.get("_material")
    if material == null or not material is ShaderMaterial:
        water.free()
        _fail("running-water material failed to initialize")
        return
    if int(WaterRuntime.MAX_SEGMENTS_PER_TILE) > 8192:
        water.free()
        _fail("hydrology tile segment cap exceeded")
        return
    water.free()

    if not References.exact_asset_path("../escape.glb").is_empty():
        _fail("downloaded asset path traversal was not rejected")
        return

    print("YARDMAN_STREAMED_CONTENT_RUNTIME_PASS cell=256 budget_us=1400 max_detail_samples=470 water_segments=8192")
    quit(0)
