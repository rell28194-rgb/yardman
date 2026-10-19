extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const FleetRegistry = preload("res://scripts/vehicle_fleet_registry.gd")

var failures := 0
var checks := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("VEHICLE_SELECTION_CONTRACT_TEST: " + message)

func _run() -> void:
    var production := Catalog.production_ids()

    _check(Catalog.has("toyota_crown"), "Crown must remain a registered owner vehicle")
    _check(production.has("toyota_crown"), "Crown must remain in the production selector")

    for banned_id in ["toyota_mark_x", "toyota_mark_x_2013", "mark_x"]:
        _check(not Catalog.has(banned_id), "banned Mark X id leaked into catalog: %s" % banned_id)
        _check(not production.has(banned_id), "banned Mark X id leaked into production selector: %s" % banned_id)

    for excluded_id in ["port_royal_992", "porsche_911_992", "992"]:
        _check(not Catalog.has(excluded_id), "excluded 992 id leaked into catalog: %s" % excluded_id)
        _check(not production.has(excluded_id), "excluded 992 id leaked into production selector: %s" % excluded_id)

    # These source-derived entries span the original recovered fleet and the
    # supplemental CarX recovery. Their private GLBs are installed only in owner
    # builds, but their catalog identities must survive in public source so the
    # build can never silently collapse back to Crown-only.
    for recovered_id in [
        "audi_r8",
        "honda_s2000",
        "nissan_skyline_r34",
        "toyota_supra_rz",
        "carx_commodore",
        "carx_pontiac_solstice",
        "carx_charger_source",
    ]:
        _check(FleetRegistry.has(recovered_id), "recovered fleet registry missing %s" % recovered_id)
        _check(Catalog.has(recovered_id), "recovered vehicle unavailable to catalog: %s" % recovered_id)
        _check(production.has(recovered_id), "recovered vehicle missing from production selector: %s" % recovered_id)

    _check(FleetRegistry.count() >= 17, "recovered fleet registry unexpectedly collapsed")

    if failures == 0:
        print("YARDMAN_VEHICLE_SELECTION_CONTRACT_TEST PASS checks=%d recovered=%d production=%d" % [checks, FleetRegistry.count(), production.size()])
        quit(0)
    else:
        print("YARDMAN_VEHICLE_SELECTION_CONTRACT_TEST FAIL failures=%d checks=%d" % [failures, checks])
        quit(1)
