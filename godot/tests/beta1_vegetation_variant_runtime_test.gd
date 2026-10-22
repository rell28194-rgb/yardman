extends SceneTree

const Variants = preload("res://scripts/beta1_vegetation_variant_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_VEGETATION_VARIANT_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    if Variants.target_cell_from_name("Plants_2_-3_palm") != Vector2i(2, -3):
        _fail("near palm cell name did not parse")
        return
    if Variants.target_cell_from_name("Plants_2_-3_palm_Distant") != Variants.INVALID_CELL:
        _fail("distant palm proxy became eligible for near mesh substitution")
        return
    if Variants.target_cell_from_name("Plants_2_-3_palm_Grass") != Variants.INVALID_CELL:
        _fail("grass proxy became eligible for palm mesh substitution")
        return
    if Variants.target_cell_from_name("Plants_nope_3_palm") != Variants.INVALID_CELL:
        _fail("malformed cell name was accepted")
        return

    var counts := {"standard": 0, "short": 0, "curved": 0}
    for z in range(-12, 13):
        for x in range(-12, 13):
            var first := Variants.variant_for_cell(Vector2i(x, z))
            var second := Variants.variant_for_cell(Vector2i(x, z))
            if first != second or not counts.has(first):
                _fail("cell variant selection is not deterministic/bounded")
                return
            counts[first] += 1
    if int(counts.short) <= 0 or int(counts.curved) <= 0 or int(counts.standard) <= 0:
        _fail("deterministic selection does not expose all recovered palm families")
        return
    if int(counts.standard) <= int(counts.short) or int(counts.standard) <= int(counts.curved):
        _fail("variant mix no longer preserves the standard palm as majority")
        return

    var contract := Variants.asset_contract()
    var variants: Dictionary = contract.get("variants", {})
    if str(variants.get("short", {}).get("file", "")) != "road_palm_short.glb" \
            or str(variants.get("curved", {}).get("file", "")) != "road_palm_curved.glb":
        _fail("recovered palm filenames drifted")
        return
    if bool(contract.get("instance_count_mutation", true)) or bool(contract.get("anchor_mutation", true)) \
            or bool(contract.get("extra_nodes", true)) or bool(contract.get("extra_draw_calls", true)) \
            or bool(contract.get("distant_lod_mutation", true)) or bool(contract.get("collision", true)):
        _fail("variant runtime gained density/batch/placement/collision authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    print("YARDMAN_BETA1_VEGETATION_VARIANT_RUNTIME_TEST PASS standard=%d short=%d curved=%d anchors_unchanged=1 instances_unchanged=1 draw_calls_unchanged=1 distant_unchanged=1 collision=0" % [counts.standard, counts.short, counts.curved])
    quit(0)
