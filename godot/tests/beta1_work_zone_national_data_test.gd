extends SceneTree

const WorkZones = preload("res://scripts/beta1_work_zone_runtime.gd")
const DATA_PATH := "res://data/roads/work_zones.json"

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_WORK_ZONE_NATIONAL_DATA_TEST: " + message)
    quit(1)

func _run() -> void:
    if not FileAccess.file_exists(DATA_PATH):
        _fail("staged national work_zones.json missing")
        return
    var payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
    if not payload_value is Dictionary:
        _fail("national sidecar is not a JSON object")
        return
    var payload: Dictionary = payload_value
    if int(payload.get("format", 0)) != 1 or bool(payload.get("drivable", true)) \
            or bool(payload.get("navigation", true)) or bool(payload.get("routing", true)) \
            or bool(payload.get("collision", true)):
        _fail("national sidecar gained gameplay authority")
        return
    if str(payload.get("source_contract", "")) != "OpenStreetMap highway=construction only":
        _fail("national sidecar source contract drifted")
        return
    var tile_size := float(payload.get("tile_size", 0.0))
    if absf(tile_size - 4096.0) > 0.001:
        _fail("national sidecar does not share Yardman's 4096 m world grid")
        return

    var runtime := WorkZones.new()
    runtime._load_contract()
    if not runtime._loaded_contract or runtime._sectors.is_empty():
        runtime.free()
        _fail("production runtime rejected the national sidecar")
        return

    var source_ways: Dictionary = {}
    var record_count := 0
    var plan_count := 0
    var closure_records := 0
    var short_fragments_rejected := 0
    for raw_sector: Variant in payload.get("sectors", []):
        if not raw_sector is Array or raw_sector.size() != 3 or not raw_sector[2] is Array:
            runtime.free()
            _fail("malformed national sector")
            return
        for raw_record: Variant in raw_sector[2]:
            if not raw_record is Dictionary:
                runtime.free()
                _fail("malformed national record")
                return
            var record: Dictionary = raw_record
            var source_way := str(record.get("source_way", ""))
            if source_way.is_empty() or float(record.get("width_m", 0.0)) <= 0.0:
                runtime.free()
                _fail("national record lost source identity/width")
                return
            source_ways[source_way] = true
            record_count += 1

            var a3: Array = record.get("a", [])
            var b3: Array = record.get("b", [])
            if a3.size() < 3 or b3.size() < 3:
                runtime.free()
                _fail("national record lost centreline endpoints")
                return
            var a := Vector2(float(a3[0]), float(a3[2]))
            var b := Vector2(float(b3[0]), float(b3[2]))
            var horizontal_length := a.distance_to(b)
            var plans := WorkZones.placement_plan(record)
            if plans.is_empty():
                # Tile splitting can leave a tiny exact boundary fragment. The
                # production runtime intentionally rejects <2 m pieces rather
                # than clustering props at a seam. Keep that safety behavior.
                if horizontal_length >= 2.0:
                    runtime.free()
                    _fail("usable >=2m national construction segment produced no bounded placement")
                    return
                short_fragments_rejected += 1
                continue

            plan_count += plans.size()
            if str(record.get("access", "")).to_lower() in ["no", "private"]:
                closure_records += 1
                var closure_found := false
                for plan: Dictionary in plans:
                    if str(plan.get("kind", "")) in ["barrier", "fence"]:
                        closure_found = true
                        break
                if not closure_found:
                    runtime.free()
                    _fail("mapped access closure lost barrier/fence presentation")
                    return

    var stats: Dictionary = payload.get("stats", {})
    if record_count != int(stats.get("segments", -1)) \
            or source_ways.size() != int(stats.get("source_ways", -1)) \
            or runtime._sectors.size() != int(stats.get("sectors", -1)):
        runtime.free()
        _fail("runtime/source counts diverged")
        return
    if plan_count <= 0:
        runtime.free()
        _fail("national source produced no runtime placements")
        return
    var snapshot: Dictionary = payload.get("source_snapshot", {})
    if str(snapshot.get("pbf_sha256", "")).length() != 64 \
            or int(snapshot.get("pbf_bytes", 0)) < 1000000:
        runtime.free()
        _fail("national source snapshot provenance missing")
        return
    runtime.free()
    print("YARDMAN_BETA1_WORK_ZONE_NATIONAL_DATA_TEST PASS ways=%d segments=%d sectors=%d plans=%d closures=%d short_rejected=%d grid=4096 gameplay_authority=0" % [source_ways.size(), record_count, int(stats.get("sectors", 0)), plan_count, closure_records, short_fragments_rejected])
    quit(0)
