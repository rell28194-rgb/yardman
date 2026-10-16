extends SceneTree

const ModelScript = preload("res://scripts/vehicle_model.gd")
var failures := 0
var checks := 0

class FakeSceneLoader:
    extends RefCounted
    var scenes: Dictionary = {}
    var requests: Array[String] = []

    func scene(filename: String) -> PackedScene:
        requests.append(filename)
        return scenes.get(filename) as PackedScene

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("VEHICLE_HERO_ASSET_TEST: " + message)

func _packed_vehicle(valid_rig: bool = true, options: Dictionary = {}) -> PackedScene:
    var vehicle_root := Node3D.new()
    vehicle_root.name = "RecoveredVehicle"

    var body_shell := Node3D.new()
    body_shell.name = "BodyShell"
    body_shell.position = Vector3(0.0, 0.70, 0.0)
    body_shell.rotation = options.get("shell_rotation", Vector3.ZERO)
    body_shell.scale = options.get("shell_scale", Vector3.ONE)
    vehicle_root.add_child(body_shell)
    body_shell.owner = vehicle_root

    var body_mesh := MeshInstance3D.new()
    body_mesh.name = "Body"
    var body_box := BoxMesh.new()
    body_box.size = options.get("body_size", Vector3(1.80, 1.40, 4.80))
    body_mesh.mesh = body_box
    body_mesh.position = options.get("body_position", Vector3.ZERO)
    body_shell.add_child(body_mesh)
    body_mesh.owner = vehicle_root

    if valid_rig:
        var wheel_data := [
            ["FrontWheelLeft", -0.77, -1.425],
            ["FrontWheelRight", 0.77, -1.425],
            ["RearWheelLeft", -0.77, 1.425],
            ["RearWheelRight", 0.77, 1.425],
        ]
        for data in wheel_data:
            var wheel_name := str(data[0])
            var pivot := Node3D.new()
            pivot.name = wheel_name
            pivot.position = Vector3(float(data[1]) * float(options.get("track_scale", 1.0)), 0.34, float(data[2]) * float(options.get("wheelbase_scale", 1.0)))
            pivot.rotation = options.get("pivot_rotation", Vector3.ZERO)
            pivot.scale = options.get("pivot_scale", Vector3.ONE)
            var pivot_parent := body_shell if bool(options.get("body_nested_wheels", false)) else vehicle_root
            pivot_parent.add_child(pivot)
            pivot.owner = vehicle_root

            var spin := Node3D.new()
            spin.name = wheel_name + "Spin"
            spin.rotation = options.get("spin_rotation", Vector3.ZERO)
            spin.scale = options.get("spin_scale", Vector3.ONE)
            pivot.add_child(spin)
            spin.owner = vehicle_root

            if not bool(options.get("empty_wheels", false)):
                var wheel_mesh := MeshInstance3D.new()
                wheel_mesh.name = "Tyre"
                var tyre_box := BoxMesh.new()
                tyre_box.size = options.get("tyre_size", Vector3(0.22, 0.68, 0.68))
                wheel_mesh.mesh = tyre_box
                spin.add_child(wheel_mesh)
                wheel_mesh.owner = vehicle_root

    var packed := PackedScene.new()
    var pack_error := packed.pack(vehicle_root)
    vehicle_root.free()
    _check(pack_error == OK, "Could not build in-memory recovered-vehicle fixture")
    return packed

func _model() -> Node3D:
    var model := ModelScript.new()
    root.add_child(model)
    return model

func _check_dedicated_identity(filename: String, vehicle_id: String, hero: PackedScene) -> void:
    var loader := FakeSceneLoader.new()
    loader.scenes[filename] = hero
    loader.scenes["road_car.glb"] = _packed_vehicle(true)
    var model = _model()
    model.call("build", filename, Callable(loader, "scene"))
    _check(bool(model.get("is_reference_model")), "%s dedicated hero did not bind" % vehicle_id)
    _check(str(model.get("reference_asset_name")) == filename, "%s did not retain its hero filename" % vehicle_id)
    _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), "%s did not mark itself as dedicated" % vehicle_id)
    _check(str(model.get_meta("yardman_dedicated_vehicle_id", "")) == vehicle_id, "%s got the wrong catalog identity" % vehicle_id)
    _check(loader.requests == [filename], "%s queried a cross-model fallback" % vehicle_id)

func _check_rejected_hero(options: Dictionary, generic: PackedScene, reason: String) -> void:
    var loader := FakeSceneLoader.new()
    loader.scenes["toyota_crown_2013.glb"] = _packed_vehicle(true, options)
    loader.scenes["road_car.glb"] = generic
    var model = _model()
    model.call("build", "toyota_crown_2013.glb", Callable(loader, "scene"))
    _check(not bool(model.get("is_reference_model")), reason + " incorrectly bound another recovered vehicle")
    _check(str(model.get("reference_asset_name")).is_empty(), reason + " incorrectly claimed a recovered identity")
    _check(bool(model.get_meta("yardman_hero_asset_missing_or_invalid", false)), reason + " did not expose the dedicated-asset failure")
    _check(str(model.get_meta("yardman_requested_hero_scene", "")) == "toyota_crown_2013.glb", reason + " lost requested Crown identity")
    _check(bool(model.get_meta("yardman_procedural_vehicle_fallback", false)), reason + " did not use the neutral procedural fallback")
    _check(loader.requests == ["toyota_crown_2013.glb"], reason + " queried a cross-model fallback")

func _check_motion_rest_pose(filename: String, mirrored: bool = false) -> void:
    var options := {
        "shell_rotation": Vector3(0.06, 0.09, -0.05),
        "pivot_rotation": Vector3(0.08, 0.12, -0.04),
        "spin_rotation": Vector3(0.13, -0.10, 0.17),
    }
    if mirrored:
        options["shell_scale"] = Vector3(-1.0, 1.05, 1.0)
        options["spin_scale"] = Vector3(-1.0, 1.0, 1.0)
        options["pivot_scale"] = Vector3(-1.0, 1.0, 1.0)
    var loader := FakeSceneLoader.new()
    loader.scenes[filename] = _packed_vehicle(true, options)
    var model = _model()
    model.call("build", filename if filename != "road_car.glb" else "", Callable(loader, "scene"))
    _check(str(model.get("reference_asset_name")) == filename, filename + " oriented fixture was rejected")
    var body: Node3D = model.get("shell")
    var spins: Array = model.get("wheels")
    var pivots: Array = model.get("front_pivots")
    var shell_rest := body.basis
    var shell_position := body.position
    var wheel_rest: Array[Basis] = []
    var wheel_scales: Array[Vector3] = []
    var pivot_rest: Array[Basis] = []
    for spin in spins:
        wheel_rest.append(Basis(spin.quaternion))
        # The stance layer runs after build; motion must preserve its scale.
        spin.scale *= 1.11
        wheel_scales.append(spin.scale)
    for pivot in pivots:
        pivot_rest.append(pivot.basis)
    model.call("update_motion", 0.1, 0.0, 0.0, 0.0, false, false, 0.0, 0.0)
    _check(body.basis.is_equal_approx(shell_rest), filename + " neutral motion erased body rest orientation")
    _check(body.position.is_equal_approx(shell_position), filename + " neutral motion moved the body")
    for index in range(spins.size()):
        _check((spins[index] as Node3D).basis.is_equal_approx(wheel_rest[index].scaled_local(wheel_scales[index])), filename + " neutral motion erased wheel rest orientation/stance scale")
    for index in range(pivots.size()):
        _check((pivots[index] as Node3D).basis.is_equal_approx(pivot_rest[index]), filename + " neutral motion erased steering rest orientation")
    var speed := 2.0
    var elapsed := 0.1
    var angle := -speed * elapsed / float(model.get("wheel_radius_m"))
    model.call("update_motion", elapsed, speed, 0.25, 0.0, false, true, 0.08, -0.06)
    for index in range(spins.size()):
        var expected := (wheel_rest[index] * Basis(Vector3.RIGHT, angle)).scaled_local(wheel_scales[index])
        _check((spins[index] as Node3D).basis.is_equal_approx(expected), filename + " wheel did not turn in its authored axle frame")
    for index in range(pivots.size()):
        var expected := Basis(Vector3.UP, 0.25) * pivot_rest[index]
        _check((pivots[index] as Node3D).basis.is_equal_approx(expected), filename + " steering lost authored alignment")
    _check(not body.basis.is_equal_approx(shell_rest), filename + " body pitch/roll did not animate")
    model.call("update_motion", elapsed, -speed, 0.0, 0.0, false, false, 0.0, 0.0)
    model.call("update_motion", 4.0, 0.0, 0.0, 0.0, false, false, 0.0, 0.0)
    _check(body.basis.is_equal_approx(shell_rest), filename + " settled body did not return to its authored orientation")
    _check(body.position.is_equal_approx(shell_position), filename + " settled body did not return to its authored height")
    for index in range(spins.size()):
        _check((spins[index] as Node3D).basis.is_equal_approx(wheel_rest[index].scaled_local(wheel_scales[index])), filename + " opposite travel failed to restore wheel orientation")
    for index in range(pivots.size()):
        _check((pivots[index] as Node3D).basis.is_equal_approx(pivot_rest[index]), filename + " straight steering failed to restore pivot orientation")

func _run() -> void:
    var hero := _packed_vehicle(true)
    var generic := _packed_vehicle(true)
    var invalid_hero := _packed_vehicle(false)

    _check_dedicated_identity("toyota_crown_2013.glb", "toyota_crown", hero)
    _check_dedicated_identity("toyota_mark_x_2013.glb", "toyota_mark_x", hero)
    _check_dedicated_identity("porsche_911_992.glb", "port_royal_992", hero)

    var invalid_loader := FakeSceneLoader.new()
    invalid_loader.scenes["toyota_crown_2013.glb"] = invalid_hero
    invalid_loader.scenes["road_car.glb"] = generic
    var invalid_model = _model()
    invalid_model.call("build", "toyota_crown_2013.glb", Callable(invalid_loader, "scene"))
    _check(not bool(invalid_model.get("is_reference_model")), "Invalid Crown silently substituted another recovered vehicle")
    _check(str(invalid_model.get("reference_asset_name")).is_empty(), "Invalid Crown claimed the wrong asset identity")
    _check(bool(invalid_model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "Invalid Crown did not expose its asset failure")
    _check(invalid_loader.requests == ["toyota_crown_2013.glb"], "Invalid Crown queried road_car.glb")

    var missing_loader := FakeSceneLoader.new()
    missing_loader.scenes["road_car.glb"] = generic
    var missing_model = _model()
    missing_model.call("build", "toyota_crown_2013.glb", Callable(missing_loader, "scene"))
    _check(not bool(missing_model.get("is_reference_model")), "Missing Crown silently substituted another recovered vehicle")
    _check(str(missing_model.get("reference_asset_name")).is_empty(), "Missing Crown claimed road_car.glb")
    _check(bool(missing_model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "Missing Crown did not expose its asset failure")
    _check(str(missing_model.get_meta("yardman_requested_hero_scene", "")) == "toyota_crown_2013.glb", "Missing Crown lost requested identity")
    _check(missing_loader.requests == ["toyota_crown_2013.glb"], "Missing Crown queried road_car.glb")

    var generic_loader := FakeSceneLoader.new()
    generic_loader.scenes["road_car.glb"] = generic
    var generic_model = _model()
    generic_model.call("build", "", Callable(generic_loader, "scene"))
    _check(str(generic_model.get("reference_asset_name")) == "road_car.glb", "Empty hero profile did not use the generic recovered sedan")
    _check(generic_loader.requests == ["road_car.glb"], "Empty hero profile queried an unexpected asset")

    var empty_loader := FakeSceneLoader.new()
    var procedural_model = _model()
    procedural_model.call("build", "toyota_crown_2013.glb", Callable(empty_loader, "scene"))
    _check(not bool(procedural_model.get("is_reference_model")), "Media-absent build did not preserve neutral procedural fallback")
    _check(str(procedural_model.get("reference_asset_name")).is_empty(), "Procedural fallback incorrectly claims a recovered asset")
    _check(procedural_model.get("shell") != null, "Procedural fallback failed to construct a body shell")
    _check(bool(procedural_model.get_meta("yardman_procedural_vehicle_fallback", false)), "Media-absent Crown did not mark procedural fallback")
    _check(empty_loader.requests == ["toyota_crown_2013.glb"], "Media-absent Crown queried a cross-model fallback")

    var wrong_root := Node.new()
    var wrong_scene := PackedScene.new()
    _check(wrong_scene.pack(wrong_root) == OK, "Could not pack wrong-root fixture")
    wrong_root.free()
    var wrong_loader := FakeSceneLoader.new()
    wrong_loader.scenes["toyota_crown_2013.glb"] = wrong_scene
    var wrong_model = _model()
    var orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
    var wrong_accepted := bool(wrong_model.call("_try_reference_sedan", "toyota_crown_2013.glb", Callable(wrong_loader, "scene")))
    _check(not wrong_accepted, "Non-3D Crown root was accepted")
    _check(str(wrong_model.get("reference_asset_name")).is_empty(), "Non-3D Crown root claimed an asset identity")
    _check(wrong_loader.requests == ["toyota_crown_2013.glb"], "Non-3D Crown root queried an unrelated asset")
    await process_frame
    var orphans_after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
    _check(orphans_after <= orphans_before, "Rejected non-3D scene increased orphan Nodes before=%d after=%d" % [orphans_before, orphans_after])

    _check_rejected_hero({"body_size": Vector3(1.8, 40.0, 4.8)}, generic, "Extreme height")
    _check_rejected_hero({"body_position": Vector3(INF, 0.0, 0.0)}, generic, "Non-finite geometry transform")
    _check_rejected_hero({"empty_wheels": true}, generic, "Empty wheel geometry")
    _check_rejected_hero({"tyre_size": Vector3(0.22, 0.08, 0.08)}, generic, "Invalid tyre radius")
    _check_rejected_hero({"body_nested_wheels": true}, generic, "Wheels coupled to body lean")
    _check_rejected_hero({"wheelbase_scale": 0.0}, generic, "Collapsed wheelbase")
    _check_rejected_hero({"wheelbase_scale": -1.0}, generic, "Reversed axles")
    _check_rejected_hero({"track_scale": 0.0}, generic, "Collapsed track")
    _check_rejected_hero({"track_scale": -1.0}, generic, "Reversed wheel sides")
    _check_motion_rest_pose("toyota_crown_2013.glb")
    _check_motion_rest_pose("road_car.glb")
    _check_motion_rest_pose("road_car.glb", true)

    print("YARDMAN_VEHICLE_HERO_ASSET_TEST %s checks=%d dedicated=3 strict_identity=3 missing_identity_guard=1 generic=1 procedural=1 authored_motion=3 geometry_rejections=9 wrong_root_cleanup=1" % ["PASS" if failures == 0 else "FAIL", checks])
    for child in root.get_children():
        if child != root:
            child.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)