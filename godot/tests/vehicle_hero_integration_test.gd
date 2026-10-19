extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Controller = preload("res://scripts/vehicle_controller.gd")

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

    for data in [
        ["FrontWheelLeft", -0.79, -1.45],
        ["FrontWheelRight", 0.79, -1.45],
        ["RearWheelLeft", -0.79, 1.45],
        ["RearWheelRight", 0.79, 1.45],
    ]:
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
    _check(packed.pack(source) == OK, "Could not pack authorized vehicle fixture")
    source.free()
    return packed

func _mesh(model: Node3D, name_value: String) -> MeshInstance3D:
    return model.find_child(name_value, true, false) as MeshInstance3D

func _check_source_preserved(model: Node3D, vehicle_id: String) -> void:
    _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), vehicle_id + " lost dedicated source metadata")
    _check(str(model.get_meta("yardman_dedicated_vehicle_id", "")) == vehicle_id, vehicle_id + " lost catalog identity")
    _check(model.scale.is_equal_approx(Vector3.ONE), vehicle_id + " applied fallback nonuniform scaling")
    _check(model.find_child("ProfileIdentityGeometry", true, false) == null, vehicle_id + " replaced source body with fallback geometry")
    _check(_mesh(model, "BodyPaint") != null, vehicle_id + " lost source body mesh")
    var paint := _mesh(model, "BodyPaint").get_active_material(0) as StandardMaterial3D
    _check(paint != null and paint.albedo_texture != null and is_equal_approx(paint.roughness, 0.19), vehicle_id + " lost authored paint")
    var interior := _mesh(model, "BodyInteriorLeather").get_active_material(0) as StandardMaterial3D
    _check(interior != null and is_equal_approx(interior.roughness, 0.81), vehicle_id + " lost authored interior")

func _exercise_vehicle(controller, runtime: Node, vehicle_id: String) -> void:
    controller.apply_profile(vehicle_id)
    _check(controller.vehicle_id == vehicle_id, "Controller did not apply " + vehicle_id)
    var model: Node3D = controller.visual
    _check_source_preserved(model, vehicle_id)
    var stats: Dictionary = runtime.style_visual(model, vehicle_id)
    _check(bool(stats.get("dedicated_mesh", false)), vehicle_id + " did not use dedicated visual branch")
    _check(not bool(stats.get("profile_geometry", true)), vehicle_id + " incorrectly overlaid fallback profile geometry")
    _check(bool(stats.get("source_materials_preserved", false)), vehicle_id + " source materials were not preserved")
    _check(bool(stats.get("source_stance_preserved", false)), vehicle_id + " authored stance was not preserved")
    var bounds: AABB = model.get("geometry_bounds")
    _check(bounds.size.x > 1.0 and bounds.size.z > 2.0, vehicle_id + " reported invalid source bounds")
    controller._update_visual(0.1, Vector3.FORWARD, 0.0)
    _check(model.scale.is_equal_approx(Vector3.ONE), vehicle_id + " driving alignment changed dedicated scale")

func _run() -> void:
    var previous_scenes: Dictionary = References._scenes
    var fixture := _packed_source()
    References._scenes = {
        "toyota_crown_2013.glb": fixture,
        "fleet_audi_r8.glb": fixture,
        "carx_commodore.glb": fixture,
    }

    var modes: Dictionary = {}
    for node in root.get_children():
        modes[node] = node.process_mode
        node.process_mode = Node.PROCESS_MODE_DISABLED

    var runtime := root.get_node_or_null("VehicleVisualRuntime")
    _check(runtime != null, "VehicleVisualRuntime autoload missing")

    var scene := Node3D.new()
    root.add_child(scene)
    var car := CharacterBody3D.new()
    var collider := CollisionShape3D.new()
    collider.shape = BoxShape3D.new()
    car.add_child(collider)
    scene.add_child(car)
    var controller = Controller.new()
    controller.configure(car, "toyota_crown")

    if runtime != null:
        _exercise_vehicle(controller, runtime, "toyota_crown")
        _exercise_vehicle(controller, runtime, "audi_r8")
        _exercise_vehicle(controller, runtime, "carx_commodore")

    for blocked_id in ["toyota_mark_x", "toyota_mark_x_2013", "mark_x", "port_royal_992", "porsche_911_992", "992"]:
        _check(not Catalog.has(blocked_id), "Blocked vehicle became available during hero integration: " + blocked_id)
        _check(not Catalog.production_ids().has(blocked_id), "Blocked vehicle entered production order: " + blocked_id)

    References._scenes = previous_scenes
    scene.free()
    await process_frame
    for node in modes:
        if is_instance_valid(node):
            node.process_mode = modes[node]

    print("YARDMAN_VEHICLE_HERO_INTEGRATION_TEST %s checks=%d current_heroes=3 blocked_legacy=6 source_materials=preserved" % [
        "PASS" if failures == 0 else "FAIL", checks])
    quit(0 if failures == 0 else 1)
