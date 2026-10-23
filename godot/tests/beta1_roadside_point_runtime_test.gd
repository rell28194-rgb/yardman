extends SceneTree

const Runtime = preload("res://scripts/beta1_roadside_point_runtime.gd")
const DATA_PATH := "res://data/roads/roadside_points.json"
const EVIDENCE_PATH := "res://docs/production_evidence/beta1-roadside-assets-001.json"
const EXPECTED_SOURCE_SHA256 := "16120becbae124393ceec1935d1fd23a3050388f39d9df338ad4e55391f7015b"
const EXPECTED_LAMP_SHA256 := "c9f9eaab8c74903aab340a1e129756ecd790d6ddf79d496edd09bfa784887761"
const EXPECTED_SHELTER_SHA256 := "5cfd95da08b3a3e616840e407a7ac932a7b5b340b0e40b135a6a7a8679869a16"
const EXPECTED_PRIVATE_PACK_SHA256 := "af58d812a62e912b7809aaa4f5501edf5ae8d32778e94ea6cadd691d2b0f7846"

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_ROADSIDE_POINT_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var lamp_record := {
        "id": "n101",
        "kind": "street_lamp",
        "position": [120.5, 77.0, -44.25],
        "source_tags": {"highway": "street_lamp"},
    }
    var lamp_copy := lamp_record.duplicate(true)
    var lamp_plan := Runtime.point_plan(lamp_record)
    if str(lamp_plan.get("kind", "")) != "street_lamp" \
            or lamp_plan.get("point", Vector2.ZERO) != Vector2(120.5, -44.25):
        _fail("explicit lamp point was not preserved exactly")
        return
    if bool(lamp_plan.get("position_inference", true)):
        _fail("lamp point gained position inference")
        return

    var shelter_record := {
        "id": "n202",
        "kind": "bus_shelter",
        "position": [-8.0, 2.0, 19.0],
        "source_tags": {"highway": "bus_stop", "shelter": "yes"},
    }
    if str(Runtime.point_plan(shelter_record).get("kind", "")) != "bus_shelter":
        _fail("shelter-authorized bus stop was rejected")
        return
    var unsheltered := shelter_record.duplicate(true)
    unsheltered.source_tags = {"highway": "bus_stop", "shelter": "no"}
    if not Runtime.point_plan(unsheltered).is_empty():
        _fail("unsheltered bus stop received shelter geometry")
        return
    var fake_lamp := lamp_record.duplicate(true)
    fake_lamp.source_tags = {"highway": "traffic_signals"}
    if not Runtime.point_plan(fake_lamp).is_empty():
        _fail("non-lamp source tag received lamp geometry")
        return
    var unknown := lamp_record.duplicate(true)
    unknown.kind = "guardrail"
    if not Runtime.point_plan(unknown).is_empty():
        _fail("unknown roadside family was accepted")
        return
    if lamp_record != lamp_copy:
        _fail("point planner mutated source truth")
        return

    var toward_road := Runtime.orientation_basis(
        Vector2(0.0, 0.0), {"point": Vector2(0.0, 10.0)}, "n101")
    var forward := toward_road.z.normalized()
    if forward.dot(Vector3(0.0, 0.0, 1.0)) < 0.99:
        _fail("orientation inference did not face nearest compiled road")
        return
    var fallback_a := Runtime.orientation_basis(Vector2.ZERO, {}, "n101")
    var fallback_b := Runtime.orientation_basis(Vector2.ZERO, {}, "n101")
    if not fallback_a.is_equal_approx(fallback_b):
        _fail("missing-road orientation fallback is not deterministic")
        return

    var contract := Runtime.asset_contract()
    var files: Dictionary = contract.get("files", {})
    if str(files.get("street_lamp", "")) != "road_lamp_single_arm.glb" \
            or str(files.get("bus_shelter", "")) != "road_bus_stop_shelter.glb":
        _fail("recovered roadside asset filenames drifted")
        return
    if bool(contract.get("position_inference", true)) \
            or bool(contract.get("routing", true)) or bool(contract.get("navigation", true)) \
            or bool(contract.get("collision", true)) or bool(contract.get("terrain_mutation", true)):
        _fail("roadside point runtime gained geographic/physics authority")
        return
    if not bool(contract.get("orientation_inference", false)) \
            or not bool(contract.get("asset_absent_fallback", false)) \
            or not bool(contract.get("data_absent_fallback", false)):
        _fail("orientation/fallback contract is incomplete")
        return
    if int(contract.get("max_points_per_tile", 999)) > 32 or float(contract.get("visibility_m", 999.0)) > 200.0:
        _fail("roadside point runtime exceeded bounded near-field budget")
        return

    if not FileAccess.file_exists(EVIDENCE_PATH):
        _fail("recovered roadside asset evidence is missing")
        return
    var evidence_raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(EVIDENCE_PATH))
    if not evidence_raw is Dictionary:
        _fail("recovered roadside asset evidence is invalid JSON")
        return
    var evidence: Dictionary = evidence_raw
    var evidence_assets: Dictionary = evidence.get("assets", {})
    var lamp_evidence: Dictionary = evidence_assets.get("road_lamp_single_arm.glb", {})
    var shelter_evidence: Dictionary = evidence_assets.get("road_bus_stop_shelter.glb", {})
    if str(lamp_evidence.get("sha256", "")) != EXPECTED_LAMP_SHA256 \
            or int(lamp_evidence.get("triangles", 0)) != 96 \
            or bool(lamp_evidence.get("rescale_applied", true)):
        _fail("recovered lamp evidence drifted")
        return
    if str(shelter_evidence.get("sha256", "")) != EXPECTED_SHELTER_SHA256 \
            or int(shelter_evidence.get("triangles", 0)) != 112 \
            or bool(shelter_evidence.get("rescale_applied", true)):
        _fail("recovered shelter evidence drifted")
        return
    var pack: Dictionary = evidence.get("canonical_private_pack", {})
    if int(pack.get("members", 0)) != 213 \
            or str(pack.get("sha256", "")) != EXPECTED_PRIVATE_PACK_SHA256 \
            or str(pack.get("zip_crc", "")) != "PASS":
        _fail("canonical private reference-pack evidence drifted")
        return
    var point_truth: Dictionary = evidence.get("jamaica_point_truth", {})
    if int(point_truth.get("points", 0)) != 38 \
            or int(point_truth.get("street_lamp", 0)) != 19 \
            or int(point_truth.get("bus_shelter", 0)) != 19 \
            or bool(point_truth.get("position_inference", true)):
        _fail("roadside evidence no longer matches Jamaica point truth")
        return

    if not FileAccess.file_exists(DATA_PATH):
        _fail("committed national roadside point sidecar is missing")
        return
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
    if not parsed is Dictionary:
        _fail("committed national roadside point sidecar is invalid JSON")
        return
    var data: Dictionary = parsed
    if int(data.get("format", 0)) != 1 or str(data.get("crs", "")) != "EPSG:3448" \
            or str(data.get("source_sha256", "")) != EXPECTED_SOURCE_SHA256:
        _fail("committed national roadside point provenance drifted")
        return
    if not bool(data.get("geographic_authority", false)) \
            or bool(data.get("routing", true)) or bool(data.get("navigation", true)) \
            or bool(data.get("collision", true)) or bool(data.get("inferred_spacing", true)):
        _fail("committed national roadside point authority flags drifted")
        return
    var stats: Dictionary = data.get("stats", {})
    var by_kind: Dictionary = stats.get("by_kind", {})
    if int(stats.get("points", 0)) != 38 or int(stats.get("tiles", 0)) != 18 \
            or int(by_kind.get("street_lamp", 0)) != 19 or int(by_kind.get("bus_shelter", 0)) != 19:
        _fail("committed national roadside point counts drifted")
        return
    var record_count := 0
    var ids: Dictionary = {}
    for sector_raw: Variant in data.get("sectors", []):
        if not sector_raw is Array or sector_raw.size() != 3 or not sector_raw[2] is Array:
            _fail("committed roadside point sector shape is invalid")
            return
        for record_raw: Variant in sector_raw[2]:
            if not record_raw is Dictionary:
                _fail("committed roadside point record is invalid")
                return
            var record: Dictionary = record_raw
            if Runtime.point_plan(record).is_empty():
                _fail("committed roadside point failed runtime authority validation")
                return
            var source_id := str(record.get("id", ""))
            if source_id.is_empty() or ids.has(source_id):
                _fail("committed roadside point identity is empty or duplicated")
                return
            ids[source_id] = true
            record_count += 1
    if record_count != 38:
        _fail("committed roadside point sector count does not match stats")
        return

    print("YARDMAN_BETA1_ROADSIDE_POINT_RUNTIME_TEST PASS lamp=1 shelter=1 unsheltered_rejected=1 fake_lamp_rejected=1 source_unchanged=1 exact_position=1 orientation_only=1 near_only=1 collision=0 national_points=38 lamps=19 shelters=19 tiles=18")
    quit(0)
