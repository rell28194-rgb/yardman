extends SceneTree

const VehicleScript = preload("res://scripts/vehicle_controller.gd")
var failures := 0
var car: CharacterBody3D
var controller = VehicleScript.new()
var reference_triangles := 0
var reference_textured_surfaces := 0
var reference_transparent_lens_surfaces := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_TEST: " + message)

func _step_frames(frames: int, throttle: float = 0.0, turn: float = 0.0, ready: bool = true) -> void:
    for frame in range(frames):
        await physics_frame
        controller.step(1.0 / 60.0, throttle, turn, ready)

func _reset() -> void:
    controller.reset_motion()
    car.position = Vector3(0, 0.15, 0)
    car.rotation = Vector3.ZERO
    controller.occupied = true
    controller.on_road = true
    await _step_frames(40)

func _inspect_reference_meshes(node: Node) -> void:
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        for surface_index in range(instance.mesh.get_surface_count()):
            var arrays: Array = instance.mesh.surface_get_arrays(surface_index)
            var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
            var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            reference_triangles += int((indices.size() if not indices.is_empty() else vertices.size()) / 3)
            var material := instance.get_active_material(surface_index) as StandardMaterial3D
            if material != null and material.albedo_texture != null:
                reference_textured_surfaces += 1
            if material != null and material.resource_name.to_lower().contains("glass"):
                reference_transparent_lens_surfaces += 1
                _check(material.transparency in [BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS], "Reference glass/lens material became opaque or alpha-clipped")
    for child in node.get_children():
        _inspect_reference_meshes(child)

func _reference_pose(node: Node3D) -> Transform3D:
    var pose := node.transform
    var parent: Node = node.get_parent()
    while parent != null and parent != controller.visual:
        if parent is Node3D:
            pose = (parent as Node3D).transform * pose
        parent = parent.get_parent()
    return pose

func _check_reference_model(scene: Node3D, collision: CollisionShape3D) -> void:
    _inspect_reference_meshes(controller.visual)
    _check(reference_triangles > 15000, "Reference sedan has been reduced to proxy geometry")
    _check(reference_textured_surfaces >= 4, "Source body/interior/tyre textures are not bound")
    _check(reference_transparent_lens_surfaces >= 2, "Source window and headlamp lens surfaces are missing")
    var bounds: AABB = controller.visual.get("geometry_bounds")
    _check(bounds.size.x > 1.7 and bounds.size.x < 2.4 and bounds.size.z > 4.4 and bounds.size.z < 5.3, "Reference vehicle has incorrect metre-scale dimensions")
    var front_pivots: Array = controller.visual.get("front_pivots")
    var wheel_spins: Array = controller.visual.get("wheels")
    var front_z := _reference_pose(front_pivots[0] as Node3D).origin.z
    var rear_z := _reference_pose((wheel_spins[2] as Node3D).get_parent() as Node3D).origin.z
    var actual_wheelbase := absf(front_z - rear_z)
    _check(actual_wheelbase > 2.3 and actual_wheelbase < 3.2 and absf(controller.wheelbase_m - actual_wheelbase) < 0.01, "Driving wheelbase does not match the actual wheel pivots")
    _check(absf(float(controller.visual.get("wheel_radius_m")) - 0.353) < 0.035, "Wheel animation radius does not match the tyres")
    _check((collision.shape as BoxShape3D).size.z > 4.3, "Vehicle collider still uses the shorter fallback body")
    var brake_material: StandardMaterial3D = controller.visual.get("brake_material")
    var reverse_material: StandardMaterial3D = controller.visual.get("reverse_material")
    _check(brake_material != null and reverse_material != null, "Source brake/reverse lamp materials were not bound")
    var second_model: Node3D = controller.visual.get_script().new()
    scene.add_child(second_model)
    second_model.call("build")
    _check(second_model.get("brake_material") != brake_material and second_model.get("reverse_material") != reverse_material, "Vehicle lamp states mutate the shared imported scene")
    controller.visual.call("update_motion", 0.1, 0.0, 0.0, 1.0, false, true, 0.0, 0.0)
    if brake_material != null:
        _check(brake_material.emission_energy_multiplier >= 2.0, "Brake lamp state did not reach the source material")
    var second_brake: StandardMaterial3D = second_model.get("brake_material")
    if second_brake != null:
        _check(second_brake.emission_energy_multiplier == 0.0, "Braking one vehicle illuminated a different vehicle")
    second_model.free()

func _check_fallback_panels() -> void:
    var paint_vertices_used := 0
    for child in controller.visual.get("shell").get_children():
        var mesh_instance := child as MeshInstance3D
        if mesh_instance == null:
            continue
        var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
        var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
        _check(not indices.is_empty(), "Material batching lost authored nonindexed panels")
        if mesh_instance.material_override.albedo_color.is_equal_approx(Color(0.14, 0.31, 0.37)):
            var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            var referenced: Dictionary = {}
            for index in indices:
                referenced[index] = true
            for index in range(vertices.size()):
                if vertices[index].z < -1.8 and vertices[index].y > 0.70 and referenced.has(index):
                    paint_vertices_used += 1
            _check(referenced.size() == vertices.size(), "Paint batch contains orphaned invisible geometry")
    _check(paint_vertices_used > 3, "Bonnet vertices are absent from the rendered paint index buffer")

func _run() -> void:
    var scene := Node3D.new()
    root.add_child(scene)
    var ground := StaticBody3D.new()
    var ground_collision := CollisionShape3D.new()
    var ground_shape := BoxShape3D.new()
    ground_shape.size = Vector3(3000, 1, 3000)
    ground_collision.shape = ground_shape
    ground.position.y = -0.5
    ground.add_child(ground_collision)
    scene.add_child(ground)
    car = CharacterBody3D.new()
    car.collision_layer = 2
    car.collision_mask = 1
    var collision := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collision.shape = shape
    collision.position.y = 0.65
    car.add_child(collision)
    var blockout := Node3D.new()
    blockout.name = "VisualRig"
    car.add_child(blockout)
    scene.add_child(car)
    controller.configure(car)
    await _reset()
    _check(car.is_on_floor(), "Vehicle did not settle on the collision floor")
    _check(car.get_node("VisualRig") == controller.visual and controller.visual != blockout, "Model did not replace the old blockout")
    _check(controller.visual.get("wheels").size() == 4 and controller.visual.get("front_pivots").size() == 2, "Four independent wheels/front steering are missing")
    _check(controller.performance_profile == VehicleScript.PROFILE_CROWN_STAGE3, "Crown Stage 3 performance profile is not active")
    var reference_model: bool = controller.visual.get("is_reference_model")
    if OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1":
        _check(reference_model, "Private preview requested without its actual sedan asset")
    if reference_model:
        _check_reference_model(scene, collision)
    else:
        _check_fallback_panels()

    await _step_frames(60, 1.0)
    var launch_state: Dictionary = controller.performance_state()
    _check(float(launch_state.front_electric_assist) > 0.5, "Front electric motors are not contributing launch torque")
    _check(float(launch_state.compound_boost) > 0.5, "Supercharger/twin-turbo compound boost is not active")
    await _step_frames(120, 1.0)
    var acceleration_speed: float = controller.speed_mps
    _check(acceleration_speed > 27.8 and acceleration_speed < 105.01, "Stage 3 Crown did not clear 100 km/h inside three seconds")
    _check(controller.odometer_m > 25.0 and car.position.z < -25.0, "Stage 3 power advanced speed without moving the actual car")
    _check(controller.engine_rpm > 2000.0 and controller.gear_label().begins_with("D"), "RPM/gear indicators did not follow Stage 3 driving")
    var spin: Node3D = controller.visual.get("wheels")[0]
    _check(absf(spin.rotation.x) > 0.01, "Wheel animation did not follow travel")

    await _step_frames(300, 1.0)
    var high_speed: float = controller.speed_mps
    _check(high_speed > 75.0 and high_speed <= 105.01, "Stage 3 Crown did not reach its expected 270+ km/h high-speed band")
    _check(controller.downforce_accel > 10.0, "High-speed active aero is not generating substantial downforce")
    _check(absf(float(controller.performance_state().top_speed_kmh) - 378.0) < 0.1, "Stage 3 limiter contract is not 378 km/h")

    controller.brake_input = 1.0
    await _step_frames(300, 1.0)
    _check(absf(controller.speed_mps) < 0.05, "Stage 3 service brakes and regen failed to stop while throttle remained pressed")
    await _step_frames(90, 0.0)
    _check(controller.speed_mps >= 0.0, "Service brake selected reverse")
    controller.brake_input = 0.0
    await _step_frames(150, -1.0)
    _check(controller.speed_mps < -3.0 and controller.speed_mps >= -12.01 and controller.gear_label() == "R", "Reverse did not work within its separate Stage 3 cap")
    var reverse_material: StandardMaterial3D = controller.visual.get("reverse_material")
    _check(reverse_material != null and reverse_material.emission_energy_multiplier > 1.0, "Reverse lamps did not illuminate")

    await _reset()
    controller.speed_mps = 85.0
    car.velocity = Vector3(0, -1.2, -85.0)
    await _step_frames(6, 0.0, 1.0)
    _check(absf(controller.steering_angle) > 0.01, "Steering input did not reach the front axle at high speed")
    _check(controller.downforce_accel > 15.0, "High-speed steering test lost the active-aero load")

    controller.on_road = false
    await _reset()
    controller.on_road = false
    await _step_frames(360, 1.0)
    _check(controller.speed_mps <= 18.01, "Grass speed exceeded its traction cap")
    controller.occupied = false
    var parked := car.global_position
    await _step_frames(30, 1.0, 1.0, false)
    _check(car.global_position.is_equal_approx(parked), "Parked vehicle moved outside collision residency")
    print("YARDMAN_VEHICLE_TEST %s launch_kmh=%.1f high_speed_kmh=%.1f downforce_mps2=%.1f stage3=1 braking=1 reverse=1 steering=1 grass=1 freeze=1 reference_model=%s triangles=%d textured_surfaces=%d" % ["PASS" if failures == 0 else "FAIL", acceleration_speed * 3.6, high_speed * 3.6, controller.downforce_accel, str(reference_model), reference_triangles, reference_textured_surfaces])
    quit(0 if failures == 0 else 1)
