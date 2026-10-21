extends SceneTree

const DetailRuntime = preload("res://scripts/world_detail_runtime.gd")
const WaterRuntime = preload("res://scripts/stream_water_runtime.gd")
const PackRuntime = preload("res://scripts/content_pack_runtime.gd")
const References = preload("res://scripts/reference_assets.gd")

const HYDROLOGY_URL := "https://github.com/rell28194-rgb/yardman/releases/download/yardman-hydrology-v1-20261021/Yardman-Hydrology-OSM-v1.zip"
const HYDROLOGY_SHA256 := "add3376085691ae9d36f5026f949defe47f1e043ac5a78d7eb53c9c8b5b17ce2"
const HYDROLOGY_BYTES := 844549

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

    var manager = PackRuntime.new()
    if not bool(manager.call("_safe_id", "world-detail")) or bool(manager.call("_safe_id", "../escape")):
        manager.free()
        _fail("content-pack identifier safety contract failed")
        return
    var valid_record := {
        "id": "test-pack",
        "label": "Test",
        "version": 1,
        "install_root": "test-pack",
        "chunks": [{
            "id": "visuals-001",
            "kind": "pck",
            "url": "https://example.invalid/test.pck",
            "sha256": "a".repeat(64),
            "bytes": 1024,
        }],
    }
    if not bool(manager.call("_validate_pack_record", valid_record)):
        manager.free()
        _fail("valid sharded PCK record was rejected")
        return
    var invalid_record: Dictionary = valid_record.duplicate(true)
    invalid_record.chunks[0].url = "http://example.invalid/test.pck"
    if bool(manager.call("_validate_pack_record", invalid_record)):
        manager.free()
        _fail("non-HTTPS content shard was accepted")
        return
    if int(PackRuntime.MAX_ZIP_ENTRY_BYTES) > 100663296:
        manager.free()
        _fail("ZIP entry memory safety cap exceeded")
        return
    manager.free()

    var catalog_raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/content_pack_catalog.json"))
    if not catalog_raw is Dictionary or int((catalog_raw as Dictionary).get("format_version", 0)) != 1:
        _fail("content-pack catalog is invalid")
        return
    var catalog: Dictionary = catalog_raw as Dictionary
    var packs: Array = catalog.get("packs", []) as Array
    if packs.size() < 4:
        _fail("content-pack catalog is missing planned world packs")
        return
    var hydrology: Dictionary = {}
    for raw_pack: Variant in packs:
        if raw_pack is Dictionary and str((raw_pack as Dictionary).get("id", "")) == "hydrology":
            hydrology = raw_pack as Dictionary
            break
    if hydrology.is_empty():
        _fail("hydrology pack missing from content catalog")
        return
    var hydrology_chunks: Array = hydrology.get("chunks", []) as Array
    if hydrology_chunks.size() != 1:
        _fail("hydrology pack must pin exactly one v1 shard")
        return
    var hydrology_chunk: Dictionary = hydrology_chunks[0] as Dictionary
    if str(hydrology_chunk.get("kind", "")) != "zip" \
        or str(hydrology_chunk.get("url", "")) != HYDROLOGY_URL \
        or str(hydrology_chunk.get("sha256", "")) != HYDROLOGY_SHA256 \
        or int(hydrology_chunk.get("bytes", 0)) != HYDROLOGY_BYTES:
        _fail("durable hydrology shard contract drifted")
        return

    if not References.exact_asset_path("../escape.glb").is_empty():
        _fail("downloaded asset path traversal was not rejected")
        return

    print("YARDMAN_STREAMED_CONTENT_RUNTIME_PASS cell=256 budget_us=1400 max_detail_samples=470 water_segments=8192 pack_manager=sharded-pck hydrology=durable")
    quit(0)
