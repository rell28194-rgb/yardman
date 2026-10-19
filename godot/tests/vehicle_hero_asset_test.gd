extends SceneTree

const ModelScript = preload("res://scripts/vehicle_model.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
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
    vehicle_root.add_child(body_shell)
    body_shell.owner = vehicle_root

    var body_mesh := MeshInstance3D.new()
    body_mesh.name = "Body"
    var body_box := BoxMesh.new()
    body_box.size = options.get("body_size", Vector3(1.80, 1.40, 4.80))
    body_mesh.mesh = body_box
    body_shell.add_child(body_mesh)
    body_mesh.owner = vehicle_root

    if valid_rig:
        for data in [
            ["FrontWheelLeft", -0.77, -1.425],
            ["FrontWheelRight", 0.77, -1.425],
            ["RearWheelLeft", -0.77, 1.425],
            ["RearWheelRight", 0.77, 1.425],
        ]:
            var pivot := Node3D.new()
            pivot.name = str(data[0])
            pivot.position = Vector3(float(data[1]), 0.34, float(data[2]))
            vehicle_root.add_child(pivot)
            pivot.owner = vehicle_root
            var spin := Node3D.new()
            spin.name = str(data[0]) + "Spin"
            pivot.add_child(spin)
            spin.owner = vehicle_root
            var tyre := MeshInstance3D.new()
            tyre.name = "Tyre"
            var tyre_box := BoxMesh.new()
            tyre_box.size = options.get("tyre_size", Vector3(0.22, 0.68, 0.68))
            tyre.mesh = tyre_box
            spin.add_child(tyre)
            tyre.owner = vehicle_root

    var packed := PackedScene.new()
    _check(packed.pack(vehicle_root) == OK, "Could not build recovered-vehicle fixture")
    vehicle_root.free()
    return packed

func _model() -> Node3D:
    var model := ModelScript.new()
    root.add_child(model)
    return model

func _check_dedicated_identity(filename: String, vehicle_id: String) -> void:
    _check(Catalog.has(vehicle_id), "Catalog lost required vehicle " + vehicle_id)
    _check(str(Catalog.profile(vehicle_id).get("hero_scene", "")) == filename,
        "%s hero filename drifted" % vehicle_id)
    var loader := FakeSceneLoader.new()
    loader.scenes[filename] = _packed_vehicle(true)
    loader.scenes["road_car.glb"] = _packed_vehicle(true)
    var model := _model()
    model.call("build", filename, Callable(loader, "scene"))
    _check(bool(model.get("is_reference_model")), "%s dedicated hero did not bind" % vehicle_id)
    _check(str(model.get("reference_asset_name")) == filename, "%s lost hero filename" % vehicle_id)
    _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), "%s was not marked dedicated" % vehicle_id)
    _check(str(model.get_meta("yardman_dedicated_vehicle_id", "")) == vehicle_id, "%s got the wrong vehicle identity" % vehicle_id)
    _check(loader.requests == [filename], "%s queried a cross-model fallback" % vehicle_id)

func _check_missing_identity_does_not_cross_fallback(filename: String) -> void:
    var loader := FakeSceneLoader.new()
    loader.scenes["road_car.glb"] = _packed_vehicle(true)
    var model := _model()
    model.call("build", filename, Callable(loader, "scene"))
    _check(not bool(model.get("is_reference_model")), "Missing dedicated hero silently substituted another recovered vehicle")
    _check(str(model.get("reference_asset_name")).is_empty(), "Missing dedicated hero claimed another identity")
    _check(bool(model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "Missing dedicated hero did not expose source failure")
    _check(str(model.get_meta("yardman_requested_hero_scene", "")) == filename, "Missing hero lost requested source identity")
    _check(loader.requests == [filename], "Missing dedicated hero queried road_car.glb")

func _check_invalid_rig_rejected(filename: String) -> void:
    var loader := FakeSceneLoader.new()
    loader.scenes[filename] = _packed_vehicle(false)
    loader.scenes["road_car.glb"] = _packed_vehicle(true)
    var model := _model()
    model.call("build", filename, Callable(loader, "scene"))
    _check(not bool(model.get("is_reference_model")), "Invalid dedicated rig was accepted")
    _check(bool(model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "Invalid dedicated rig did not expose failure")
    _check(loader.requests == [filename], "Invalid dedicated rig queried cross-model fallback")

func _check_authored_motion(filename: String) -> void:
    var loader := FakeSceneLoader.new()
    loader.scenes[filename] = _packed_vehicle(true, {"shell_rotation": Vector3(0.04, 0.08, -0.03)})
    var model := _model()
    model.call("build", filename, Callable(loader, "scene"))
    _check(bool(model.get("is_reference_model")), filename + " motion fixture did not bind")
    var shell: Node3D = model.get("shell")
    var before := shell.basis
    model.call("update_motion", 0.1, 4.0, 0.2, 0.0, false, true, 0.05, -0.04)
    _check(not shell.basis.is_equal_approx(before), filename + " body motion did not animate")
    model.call("update_motion", 4.0, 0.0, 0.0, 0.0, false, false, 0.0, 0.0)
    _check(shell.basis.is_equal_approx(before), filename + " body did not settle to authored rest pose")

func _run() -> void:
    # Current owner authority: Crown plus recovered production fleet. Mark X is
    # banned and 992 excluded, so neither may be a required hero in this test.
    _check_dedicated_identity("toyota_crown_2013.glb", "toyota_crown")
    _check_dedicated_identity("fleet_audi_r8.glb", "audi_r8")
    _check_dedicated_identity("carx_commodore.glb", "carx_commodore")

    for blocked_id in ["toyota_mark_x", "toyota_mark_x_2013", "mark_x", "port_royal_992", "porsche_911_992", "992"]:
        _check(not Catalog.has(blocked_id), "Blocked vehicle leaked back into catalog: " + blocked_id)
        _check(not Catalog.production_ids().has(blocked_id), "Blocked vehicle leaked back into production selector: " + blocked_id)

    _check_missing_identity_does_not_cross_fallback("toyota_crown_2013.glb")
    _check_missing_identity_does_not_cross_fallback("fleet_audi_r8.glb")
    _check_invalid_rig_rejected("toyota_crown_2013.glb")
    _check_invalid_rig_rejected("fleet_audi_r8.glb")
    _check_authored_motion("toyota_crown_2013.glb")
    _check_authored_motion("fleet_audi_r8.glb")

    var generic_loader := FakeSceneLoader.new()
    generic_loader.scenes["road_car.glb"] = _packed_vehicle(true)
    var generic_model := _model()
    generic_model.call("build", "", Callable(generic_loader, "scene"))
    _check(bool(generic_model.get("is_reference_model")), "Generic recovered sedan fixture did not bind")
    _check(not bool(generic_model.get_meta("yardman_dedicated_vehicle_mesh", false)), "Generic fallback claimed production identity")
    _check(generic_loader.requests == ["road_car.glb"], "Generic fallback queried unexpected media")

    print("YARDMAN_VEHICLE_HERO_ASSET_TEST %s checks=%d dedicated_current=3 blocked_legacy=6 cross_model_fallback=0" % [
        "PASS" if failures == 0 else "FAIL", checks])
    quit(0 if failures == 0 else 1)
