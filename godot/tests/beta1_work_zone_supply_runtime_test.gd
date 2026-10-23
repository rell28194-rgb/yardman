extends SceneTree

const SupplyRuntime = preload("res://scripts/beta1_work_zone_supply_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_WORK_ZONE_SUPPLY_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var tile := Node3D.new()
    tile.name = "RoadTile_-4_7"
    root.add_child(tile)
    var work_zones := Node3D.new()
    work_zones.name = "Beta1WorkZones"
    work_zones.set_meta("source_contract", SupplyRuntime.SOURCE_CONTRACT)
    work_zones.set_meta("presentation_inference", true)
    work_zones.set_meta("drivable", false)
    work_zones.set_meta("navigation", false)
    work_zones.set_meta("collision", false)
    tile.add_child(work_zones)

    if not SupplyRuntime.eligible_root(work_zones):
        _fail("valid OSM construction root was rejected")
        return
    if SupplyRuntime.tile_from_ancestors(work_zones) != Vector2i(-4, 7):
        _fail("road-tile ancestry did not resolve")
        return

    var anchor := Transform3D(Basis(Vector3.UP, 0.63), Vector3(12.0, 5.0, -3.0))
    var poses: Array[Transform3D] = [anchor]
    if not SupplyRuntime.valid_source_poses(poses):
        _fail("valid CPU cone pose was rejected")
        return
    if SupplyRuntime.valid_source_poses([]) or SupplyRuntime.valid_source_poses(["fake"]):
        _fail("invalid source poses were accepted")
        return
    var placed := SupplyRuntime.supply_pose_from_anchor(anchor)
    var expected := anchor.origin + anchor.basis.z.normalized() * SupplyRuntime.ALONG_ROAD_OFFSET_M
    if not placed.origin.is_equal_approx(expected):
        _fail("crate did not remain on the cone's existing off-pavement line")
        return
    if not placed.basis.is_equal_approx(anchor.basis.orthonormalized()):
        _fail("crate orientation drifted from the source-backed roadwork anchor")
        return

    var selected := 0
    var skipped := 0
    for z in range(-12, 13):
        for x in range(-12, 13):
            var first := SupplyRuntime.uses_supply_for_tile(Vector2i(x, z))
            var second := SupplyRuntime.uses_supply_for_tile(Vector2i(x, z))
            if first != second:
                _fail("tile selection is not deterministic")
                return
            if first:
                selected += 1
            else:
                skipped += 1
    if selected <= 0 or skipped <= 0 or selected * 2 >= skipped:
        _fail("supply-crate density is no longer sparse")
        return

    work_zones.set_meta("source_contract", "foreign source yard")
    if SupplyRuntime.eligible_root(work_zones):
        _fail("foreign source-map root became eligible")
        return

    var contract := SupplyRuntime.asset_contract()
    if str(contract.get("file", "")) != "road_work_supply_crate.glb" \
            or str(contract.get("source_sha256", "")) != "01e3ff3602769c840c6c89cf20985feaad120120848d3cd483af3da1e97f7606":
        _fail("recovered crate identity drifted")
        return
    if int(contract.get("max_instances_per_work_zone_tile", 99)) != 1 or int(contract.get("variant_modulus", 0)) != 5:
        _fail("crate density budget drifted")
        return
    if bool(contract.get("source_map_coordinates", true)) or bool(contract.get("anchor_mutation", true)) \
            or bool(contract.get("collision", true)) or bool(contract.get("navigation", true)) \
            or bool(contract.get("terrain_mutation", true)) or bool(contract.get("random_jamaica_placement", true)):
        _fail("crate runtime gained forbidden world authority")
        return
    if not bool(contract.get("source_scale_preserved", false)) or not bool(contract.get("asset_absent_fallback", false)):
        _fail("source scale/fallback contract missing")
        return

    print("YARDMAN_BETA1_WORK_ZONE_SUPPLY_RUNTIME_TEST PASS source_gate=1 exact_hash=1 sparse=1 max_per_tile=1 source_coords=0 anchor_mutation=0 collision=0 navigation=0 terrain_mutation=0 fallback=1")
    quit(0)
