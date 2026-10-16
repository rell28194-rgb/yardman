extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Controller = preload("res://scripts/vehicle_controller.gd")
const ModelScript = preload("res://scripts/vehicle_model.gd")

class FixtureGarage:
    extends "res://scripts/vehicle_garage.gd"
    func _load_selection() -> void:
        _selected_id = "toyota_crown"
        _owned_ids = ["toyota_crown", "toyota_mark_x", "port_royal_992"]

var failures := 0
var checks := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("VEHICLE_HERO_INTEGRATION_TEST: " + message)

func _material(label: String, color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.resource_name = label
    material.albedo_color = color
    material.roughness = roughness
    return material

func _box(parent: Node3D, owner_root: Node3D, label: String, size: Vector3, position: Vector3, material: Material) -> MeshInstance3D:
    var node := MeshInstance3D.new()
    node.name = label
    var mesh := BoxMesh.new()
    mesh.size = size
    mesh.material = material
    node.mesh = mesh
    node.position = position
    parent.add_child(node)
    node.owner = owner_root
    return node

func _packed_source() -> PackedScene:
    var source := Node3D.new()
    source.name = "GeneratedAuthorizedVehicleFixture"
    var shell := Node3D.new()
    shell.name = "BodyShell"
    source.add_child(shell)
    shell.owner = source
    var paint := _material("RecoveredBodyPaint", Color(0.60, 0.16, 0.06), 0.19)
    paint.clearcoat_enabled = true
    paint.clearcoat_roughness = 0.16
    var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.43, 0.28, 0.11))
    paint.albedo_texture = ImageTexture.create_from_image(image)
    _box(shell, source, "BodyPaint", Vector3(1.82, 1.50, 4.95), Vector3(0, 0.75, 0), paint)
    var interior := _material("DoorInteriorLeather", Color(0.42, 0.18, 0.09), 0.81)
    _box(shell, source, "BodyInteriorLeather", Vector3(1.30, 0.35, 1.30), Vector3(0, 0.86, 0), interior)
    var glass := _material("SourceWindshieldGlass", Color(0.1, 0.2, 0.3, 0.27), 0.19)
    glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
    _box(shell, source, "WindshieldGlass", Vector3(1.3, 0.4, 0.03), Vector3(0, 1.10, -0.95), glass)
    _box(shell, source, "RearStoplight", Vector3(0.4, 0.1, 0.03), Vector3(-0.5, 0.7, 2.48), _material("SourceStoplight", Color(0.5, 0.02, 0.01), 0.23))
    _box(shell, source, "RearReverseLamp", Vector3(0.1, 0.05, 0.03), Vector3(0.4, 0.7, 2.48), _material("SourceLightsRear", Color(0.8, 0.8, 0.7), 0.25))
    for data in [["FrontWheelLeft", -0.79, -1.45], ["FrontWheelRight", 0.79, -1.45], ["RearWheelLeft", -0.79, 1.45], ["RearWheelRight", 0.79, 1.45]]:
        var pivot := Node3D.new()
        pivot.name = str(data[0])
        pivot.position = Vector3(float(data[1]), 0.36, float(data[2]))
        source.add_child(pivot)
        pivot.owner = source
        var spin := Node3D.new()
        spin.name = str(data[0]) + "Spin"
        pivot.add_child(spin)
        spin.owner = source
        _box(spin, source, "AlloyWheel", Vector3(0.22, 0.72, 0.72), Vector3.ZERO, _material("SourceAlloyRim", Color(0.25, 0.21, 0.17), 0.67))
    var packed := PackedScene.new()
    _check(packed.pack(source) == OK, "Could not pack the generated hero fixture")
    source.free()
    return packed

func _mesh(model: Node3D, name_value: String) -> MeshInstance3D:
    return model.find_child(name_value, true, false) as MeshInstance3D

func _capture_source_state(model: Node3D) -> Dictionary:
    var result := {"materials": {}, "rig": {}, "children": model.find_children("*", "", true, false).size()}
    for label in ["BodyPaint", "BodyInteriorLeather", "WindshieldGlass", "RearStoplight", "RearReverseLamp"]:
        var instance := _mesh(model, label)
        result.materials[label] = instance.get_active_material(0)
    for spin in model.get("wheels"):
        result.rig[str(spin.get_parent().name)] = spin.get_parent().transform
        result.rig[str(spin.name)] = spin.transform
    return result

func _check_source_preserved(model: Node3D, before: Dictionary, label: String) -> void:
    _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), label + " lost dedicated metadata")
    _check(str(model.get_meta("yardman_dedicated_vehicle_id", "")) == "toyota_crown", label + " lost source vehicle identity")
    _check(model.scale.is_equal_approx(Vector3.ONE), label + " applied fallback nonuniform visual scale")
    _check(model.find_child("ProfileIdentityGeometry", true, false) == null, label + " replaced the source body with a fallback kit")
    _check(_mesh(model, "BodyPaint").visible, label + " hid the actual recovered body")
    _check(model.find_children("*", "", true, false).size() == int(before.children), label + " allocated replacement geometry")
    for material_label in before.materials:
        _check(_mesh(model, str(material_label)).get_active_material(0) == before.materials[material_label], label + " replaced authored " + str(material_label) + " material")
    for spin in model.get("wheels"):
        _check(spin.get_parent().transform.is_equal_approx(before.rig[str(spin.get_parent().name)]), label + " moved an authored wheel pivot")
        _check(spin.transform.is_equal_approx(before.rig[str(spin.name)]), label + " rescaled an authored spindle")

func _run() -> void:
    # Seed only in-memory trusted fixtures and restore the exact prior cache.
    # No source media, manifests, owner settings or asset directories are changed.
    var previous_scenes: Dictionary = References._scenes
    References._scenes = {"toyota_crown_2013.glb": _packed_source()}
    var modes: Dictionary = {}
    for node in root.get_children():
        modes[node] = node.process_mode
        node.process_mode = Node.PROCESS_MODE_DISABLED
    var previous_pause := paused
    paused = false
    var runtime = root.get_node("VehicleVisualRuntime")
    var scene := Node3D.new()
    root.add_child(scene)
    var car := CharacterBody3D.new()
    var collider := CollisionShape3D.new()
    collider.shape = BoxShape3D.new()
    car.add_child(collider)
    scene.add_child(car)
    var controller = Controller.new()
    controller.configure(car, "toyota_crown")
    var model: Node3D = controller.visual
    var source_state := _capture_source_state(model)
    var stats: Dictionary = runtime.style_visual(model, "toyota_crown")
    _check_source_preserved(model, source_state, "World hero")
    _check(bool(stats.get("dedicated_mesh", false)) and not bool(stats.get("profile_geometry", true)), "Runtime did not select the dedicated source branch")
    _check(bool(stats.get("source_materials_preserved", false)), "Runtime did not preserve source material translation")
    _check(int(stats.get("stance_wheels", -1)) == 0, "Runtime repositioned dedicated source wheels")
    _check(bool(stats.get("source_stance_preserved", false)), "Runtime did not report its authored stance branch")
    _check(absf(controller.wheelbase_m - 2.90) < 0.001, "Controller driving wheelbase differs from authored axles")
    _check(absf(float(controller.get("_track_half_m")) - 0.79) < 0.001, "Controller ground contacts differ from authored track")
    var bounds: AABB = model.get("geometry_bounds")
    _check((collider.shape as BoxShape3D).size.is_equal_approx(Vector3(bounds.size.x * 0.94, maxf(bounds.size.y * 0.76, 0.92), bounds.size.z * 0.91)), "Collision dimensions did not use actual source bounds")
    var headlights: Array = controller.get("_headlights")
    _check(headlights.size() == 2 and absf((headlights[0] as SpotLight3D).position.z - (bounds.position.z - 0.06)) < 0.001, "Headlights use fallback body length")
    var paint := _mesh(model, "BodyPaint").get_active_material(0) as StandardMaterial3D
    _check(paint.albedo_texture != null and is_equal_approx(paint.roughness, 0.19), "Authored paint texture/roughness was lost")
    var interior := _mesh(model, "BodyInteriorLeather").get_active_material(0) as StandardMaterial3D
    _check(interior.albedo_color.is_equal_approx(Color(0.42, 0.18, 0.09)) and is_equal_approx(interior.roughness, 0.81), "Interior was repainted by broad body/door heuristics")
    var glass := _mesh(model, "WindshieldGlass").get_active_material(0) as StandardMaterial3D
    _check(glass.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS and is_equal_approx(glass.albedo_color.a, 0.27), "Source glass transmission was replaced")
    runtime.style_visual(model, "toyota_crown")
    _check_source_preserved(model, source_state, "Repeated world styling")
    controller._update_visual(0.1, Vector3.FORWARD, 0.0)
    _check(model.scale.is_equal_approx(Vector3.ONE), "Driving ground alignment changed hero scale")
    model.call("update_motion", 0.1, 0.0, 0.0, 1.0, true, true, 0.0, 0.0)
    _check(is_equal_approx((model.get("brake_material") as StandardMaterial3D).emission_energy_multiplier, 2.0), "Brake lamp lost runtime control")
    _check(is_equal_approx((model.get("reverse_material") as StandardMaterial3D).emission_energy_multiplier, 1.4), "Reverse lamp lost runtime control")

    var garage := FixtureGarage.new()
    root.add_child(garage)
    garage.set_process(false)
    _check(garage.get("_preview_model") == null, "Hidden garage allocated a source preview")
    garage.open_garage()
    var preview: Node3D = garage.get("_preview_model")
    _check(preview != null, "Garage did not construct the source preview")
    if preview != null:
        var preview_state := _capture_source_state(preview)
        runtime.style_visual(preview, "toyota_crown")
        _check_source_preserved(preview, preview_state, "Garage hero")
        _check(preview.get("brake_material") != model.get("brake_material"), "Garage and world share mutable lamp state")
        _check(is_zero_approx((preview.get("brake_material") as StandardMaterial3D).emission_energy_multiplier), "World brake state leaked into preview")
        garage._refresh_preview()
        _check(garage.get("_preview_model") == preview, "Unchanged garage selection rebuilt the hero")
    garage.close_garage()
    _check((garage.get("_preview_viewport") as SubViewport).render_target_update_mode == SubViewport.UPDATE_DISABLED, "Closed hero preview consumes continuous renderer work")

    # The generic recovered sedan and asset-absent paths remain profile-driven.
    for recovered in [false, true]:
        References._scenes = {"road_car.glb": _packed_source()} if recovered else {}
        var signatures: Array[String] = []
        for vehicle_id in Catalog.production_ids():
            controller.apply_profile(str(vehicle_id))
            var fallback: Node3D = controller.visual
            var fallback_stats: Dictionary = runtime.style_visual(fallback, str(vehicle_id))
            _check(not bool(fallback.get_meta("yardman_dedicated_vehicle_mesh", false)), "Fallback incorrectly claims a dedicated identity")
            _check(bool(fallback_stats.get("profile_geometry", false)), "Fallback lost its production profile geometry")
            _check(int(fallback_stats.get("stance_wheels", 0)) == 4, "Fallback lost four-wheel stance adaptation")
            var profile_scale: Array = Catalog.profile(str(vehicle_id)).visual_scale
            var expected_scale := Vector3(float(profile_scale[0]), float(profile_scale[1]), float(profile_scale[2]))
            _check(fallback.scale.is_equal_approx(expected_scale), "Fallback legacy visual scale changed")
            controller._update_visual(0.1, Vector3.FORWARD, 0.0)
            _check(fallback.scale.is_equal_approx(expected_scale), "Driving ground alignment erased fallback visual scale")
            controller.reset_motion()
            _check(fallback.scale.is_equal_approx(expected_scale), "Motion reset erased fallback visual scale")
            signatures.append(str(fallback_stats.get("geometry_signature", "")))
        _check(signatures[0] != signatures[1] and signatures[1] != signatures[2] and signatures[0] != signatures[2], "Three fallback silhouettes are no longer distinct")

    References._scenes = previous_scenes
    garage.free()
    scene.free()
    await process_frame
    for node in modes:
        if is_instance_valid(node):
            node.process_mode = modes[node]
    paused = previous_pause
    print("YARDMAN_VEHICLE_HERO_INTEGRATION_TEST %s checks=%d controller=1 garage=1 dedicated_body=1 authored_materials=1 authored_stance=1 fallback_profiles=6" % ["PASS" if failures == 0 else "FAIL", checks])
    quit(0 if failures == 0 else 1)
