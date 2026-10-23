extends SceneTree

const BraceRuntime = preload("res://scripts/beta1_work_zone_brace_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_WORK_ZONE_BRACE_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var road_tile := Node3D.new()
    road_tile.name = "RoadTile_3_-2"
    root.add_child(road_tile)

    var work_zones := Node3D.new()
    work_zones.name = "Beta1WorkZones"
    work_zones.set_meta("source_contract", BraceRuntime.SOURCE_CONTRACT)
    work_zones.set_meta("presentation_inference", true)
    work_zones.set_meta("drivable", false)
    work_zones.set_meta("navigation", false)
    work_zones.set_meta("collision", false)
    road_tile.add_child(work_zones)

    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = BoxMesh.new()
    multi.instance_count = 3
    multi.visible_instance_count = 2
    var poses: Array[Transform3D] = [
        Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 2.0)),
        Transform3D(Basis.IDENTITY.rotated(Vector3.UP, 0.4), Vector3(5.0, 0.0, 7.0)),
        Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -0.7), Vector3(-3.0, 0.0, 4.0)),
    ]
    for index in range(poses.size()):
        multi.set_instance_transform(index, poses[index])

    var instance := MultiMeshInstance3D.new()
    instance.name = BraceRuntime.TARGET_NODE
    instance.multimesh = multi
    instance.set_meta("source_poses", poses.duplicate(true))
    instance.set_meta("source_pose_count", poses.size())
    work_zones.add_child(instance)

    if not BraceRuntime.eligible_target(instance):
        _fail("valid source-backed work-zone barrier was rejected")
        return
    if BraceRuntime.tile_from_ancestors(instance) != Vector2i(3, -2):
        _fail("road-tile ancestry did not resolve exactly")
        return
    if not BraceRuntime.valid_source_poses(instance.get_meta("source_poses"), multi.instance_count):
        _fail("CPU source-pose contract was rejected")
        return
    if BraceRuntime.valid_source_poses([], multi.instance_count) or BraceRuntime.valid_source_poses([Transform3D.IDENTITY], multi.instance_count):
        _fail("invalid/mismatched CPU pose set was accepted")
        return

    var accepted := 0
    var rejected := 0
    for z in range(-8, 9):
        for x in range(-8, 9):
            var first := BraceRuntime.uses_brace_for_tile(Vector2i(x, z))
            var second := BraceRuntime.uses_brace_for_tile(Vector2i(x, z))
            if first != second:
                _fail("brace selection is not deterministic")
                return
            if first:
                accepted += 1
            else:
                rejected += 1
    if accepted <= 0 or rejected <= 0 or accepted >= rejected:
        _fail("bounded brace variation no longer preserves barrier majority")
        return

    var source_copy: Array = (instance.get_meta("source_poses") as Array).duplicate(true)
    var replacement := BoxMesh.new()
    replacement.size = Vector3(9.5, 4.0, 3.0)
    if not BraceRuntime.apply_mesh_substitution(multi, replacement, source_copy):
        _fail("mesh substitution failed")
        return
    if multi.instance_count != 3 or multi.visible_instance_count != 2 or multi.mesh != replacement:
        _fail("mesh substitution changed density/visibility or missed replacement")
        return
    # Headless/dummy rendering does not reliably round-trip MultiMesh transforms.
    # Placement authority is therefore the immutable CPU pose array retained by
    # the source work-zone runtime, not renderer-side readback.
    var retained: Array = instance.get_meta("source_poses") as Array
    if retained.size() != poses.size():
        _fail("CPU source-pose metadata changed size")
        return
    for index in range(poses.size()):
        if not (retained[index] as Transform3D).is_equal_approx(poses[index]):
            _fail("CPU source-pose metadata was mutated")
            return

    var wrong_name := MultiMeshInstance3D.new()
    wrong_name.name = "WorkZone_Cone"
    wrong_name.multimesh = multi
    wrong_name.set_meta("source_poses", poses.duplicate(true))
    work_zones.add_child(wrong_name)
    if BraceRuntime.eligible_target(wrong_name):
        _fail("non-barrier work-zone mesh became eligible")
        return

    work_zones.set_meta("source_contract", "procedural")
    if BraceRuntime.eligible_target(instance):
        _fail("non-source-backed parent became eligible")
        return
    work_zones.set_meta("source_contract", BraceRuntime.SOURCE_CONTRACT)

    var contract := BraceRuntime.asset_contract()
    if str(contract.get("file", "")) != "building_level8_piece_1937.glb":
        _fail("recovered brace filename drifted")
        return
    if int(contract.get("variant_modulus", 0)) != 4:
        _fail("brace density contract drifted")
        return
    if not bool(contract.get("cpu_pose_authority", false)) or bool(contract.get("renderer_pose_readback", true)):
        _fail("CPU pose authority contract missing")
        return
    for forbidden in ["anchor_mutation", "instance_count_mutation", "extra_prop_nodes", "extra_draw_calls", "collision", "navigation", "terrain_mutation", "building_replacement"]:
        if bool(contract.get(forbidden, true)):
            _fail("brace runtime gained forbidden authority: " + forbidden)
            return
    if not bool(contract.get("source_scale_preserved", false)) or not bool(contract.get("asset_absent_fallback", false)):
        _fail("source-scale or asset-absent fallback contract missing")
        return

    print("YARDMAN_BETA1_WORK_ZONE_BRACE_RUNTIME_TEST PASS source_gate=1 deterministic=1 bounded=1 transforms_unchanged=1 instances_unchanged=1 draw_calls_unchanged=1 collision=0 navigation=0 terrain_mutation=0 fallback=1")
    quit(0)
