extends SceneTree

const ModelScript = preload("res://scripts/vehicle_model.gd")
var failures := 0

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
    if not condition:
        failures += 1
        push_error("VEHICLE_HERO_ASSET_TEST: " + message)

func _packed_vehicle(valid_rig: bool = true) -> PackedScene:
    var vehicle_root := Node3D.new()
    vehicle_root.name = "RecoveredVehicle"

    var body_shell := Node3D.new()
    body_shell.name = "BodyShell"
    body_shell.position = Vector3(0.0, 0.70, 0.0)
    vehicle_root.add_child(body_shell)
    body_shell.owner = vehicle_root

    var body_mesh := MeshInstance3D.new()
    body_mesh.name = "Body"
    var body_box := BoxMesh.new()
    body_box.size = Vector3(1.80, 1.40, 4.80)
    body_mesh.mesh = body_box
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
            pivot.position = Vector3(float(data[1]), 0.34, float(data[2]))
            vehicle_root.add_child(pivot)
            pivot.owner = vehicle_root

            var spin := Node3D.new()
            spin.name = wheel_name + "Spin"
            pivot.add_child(spin)
            spin.owner = vehicle_root

            var wheel_mesh := MeshInstance3D.new()
            wheel_mesh.name = "Tyre"
            var tyre_box := BoxMesh.new()
            tyre_box.size = Vector3(0.22, 0.68, 0.68)
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

func _run() -> void:
    var hero := _packed_vehicle(true)
    var generic := _packed_vehicle(true)
    var invalid_hero := _packed_vehicle(false)

    var hero_loader := FakeSceneLoader.new()
    hero_loader.scenes["toyota_crown_2013.glb"] = hero
    hero_loader.scenes["road_car.glb"] = generic
    var hero_model = _model()
    hero_model.call("build", "toyota_crown_2013.glb", Callable(hero_loader, "scene"))
    _check(bool(hero_model.get("is_reference_model")), "Dedicated Crown hero did not bind")
    _check(str(hero_model.get("reference_asset_name")) == "toyota_crown_2013.glb", "Dedicated hero identity was not retained")
    _check(hero_loader.requests == ["toyota_crown_2013.glb"], "Generic fallback was queried even though the hero was valid")

    var invalid_loader := FakeSceneLoader.new()
    invalid_loader.scenes["toyota_crown_2013.glb"] = invalid_hero
    invalid_loader.scenes["road_car.glb"] = generic
    var invalid_model = _model()
    invalid_model.call("build", "toyota_crown_2013.glb", Callable(invalid_loader, "scene"))
    _check(bool(invalid_model.get("is_reference_model")), "Invalid hero did not fall back to the generic recovered sedan")
    _check(str(invalid_model.get("reference_asset_name")) == "road_car.glb", "Invalid hero selected the wrong fallback asset")
    _check(invalid_loader.requests == ["toyota_crown_2013.glb", "road_car.glb"], "Invalid hero fallback order changed")

    var missing_loader := FakeSceneLoader.new()
    missing_loader.scenes["road_car.glb"] = generic
    var missing_model = _model()
    missing_model.call("build", "toyota_crown_2013.glb", Callable(missing_loader, "scene"))
    _check(str(missing_model.get("reference_asset_name")) == "road_car.glb", "Missing hero did not fall back to road_car.glb")
    _check(missing_loader.requests == ["toyota_crown_2013.glb", "road_car.glb"], "Missing hero fallback order changed")

    var generic_loader := FakeSceneLoader.new()
    generic_loader.scenes["road_car.glb"] = generic
    var generic_model = _model()
    generic_model.call("build", "", Callable(generic_loader, "scene"))
    _check(str(generic_model.get("reference_asset_name")) == "road_car.glb", "Empty hero profile did not use the generic recovered sedan")
    _check(generic_loader.requests == ["road_car.glb"], "Empty hero profile queried an unexpected asset")

    var empty_loader := FakeSceneLoader.new()
    var procedural_model = _model()
    procedural_model.call("build", "toyota_crown_2013.glb", Callable(empty_loader, "scene"))
    _check(not bool(procedural_model.get("is_reference_model")), "Media-absent build did not preserve procedural fallback")
    _check(str(procedural_model.get("reference_asset_name")).is_empty(), "Procedural fallback incorrectly claims a recovered asset")
    _check(procedural_model.get("shell") != null, "Procedural fallback failed to construct a body shell")
    _check(empty_loader.requests == ["toyota_crown_2013.glb", "road_car.glb"], "Media-absent fallback did not exhaust the intended reference order")

    print("YARDMAN_VEHICLE_HERO_ASSET_TEST %s dedicated=1 invalid_fallback=1 missing_fallback=1 generic=1 procedural=1" % ("PASS" if failures == 0 else "FAIL"))
    for child in root.get_children():
        if child != root:
            child.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
