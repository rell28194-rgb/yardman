extends SceneTree

const VehicleScript = preload("res://scripts/vehicle_controller.gd")
var failures := 0
var car: CharacterBody3D
var controller = VehicleScript.new()
var reference_triangles := 0
var reference_textured_surfaces := 0

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
    for child in node.get_children():
        _inspect_reference_meshes(child)

func _check_reference_model(scene: Node3D, collision: CollisionShape3D) -> void:
    _inspect_reference_meshes(controller.visual)
    _check(reference_triangles > 15000, "Reference sedan has been reduced to proxy geometry")
    _check(reference_textured_surfaces >= 4, "Source body/interior/tyre textures are not bound")
    var bounds: AABB = controller.visual.get("geometry_bounds")
    _check(bounds.size.x > 1.7 and bounds.size.x < 2.4 and bounds.size.z > 4.4 and bounds.size.z < 5.3, "Reference vehicle has incorrect metre-scale dimensions")
    _check(absf(controller.wheelbase_m - 2.673) < 0.08, "Driving wheelbase does not match the actual wheel pivots")
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
    var reference_model: bool = controller.visual.get("is_reference_model")
    if OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1":
        _check(reference_model, "Private preview requested without its actual sedan asset")
    if reference_model:
        _check_reference_model(scene, collision)
    else:
        _check_fallback_panels()
    await _step_frames(420, 1.0)
    var acceleration_speed: float = controller.speed_mps
    _check(acceleration_speed > 27.8 and acceleration_speed < 42.01, "Seven seconds of road acceleration did not reach 100 km/h within its cap")
    _check(controller.odometer_m > 60.0 and car.position.z < -60.0, "Engine input advanced speed without moving the actual car")
    _check(controller.engine_rpm > 1500.0 and controller.gear_label().begins_with("D"), "RPM/gear indicators did not follow driving")
    var spin: Node3D = controller.visual.get("wheels")[0]
    _check(absf(spin.rotation.x) > 0.01, "Wheel animation did not follow travel")
    controller.brake_input = 1.0
    await _step_frames(240, 1.0)
    _check(absf(controller.speed_mps) < 0.05, "Service brake failed to stop while throttle remained pressed")
    await _step_frames(90, 0.0)
    _check(controller.speed_mps >= 0.0, "Service brake selected reverse")
    controller.brake_input = 0.0
    await _step_frames(150, -1.0)
    _check(controller.speed_mps < -3.0 and controller.speed_mps >= -7.01 and controller.gear_label() == "R", "Reverse did not work within its separate cap")
    var reverse_material: StandardMaterial3D = controller.visual.get("reverse_material")
    _check(reverse_material != null and reverse_material.emission_energy_multiplier > 1.0, "Reverse lamps did not illuminate")
    await _reset()
    controller.speed_mps = 35.0
    car.velocity = Vector3(0, -1.2, -35.0)
    await _step_frames(6, 0.0, 1.0)
    _check(absf(car.rotation.y) < 0.035 and absf(car.rotation.y) > 0.0001, "High-speed full-lock steering is unbounded or inert")
    var front_pivot: Node3D = controller.visual.get("front_pivots")[0]
    _check(absf(front_pivot.rotation.y) > 0.01, "Front wheels did not visibly steer")
    await _reset()
    controller.speed_mps = 35.0
    car.velocity = Vector3(0, -1.2, -35.0)
    controller.on_road = false
    await _step_frames(1, 1.0)
    _check(controller.speed_mps > 30.0, "Road-to-grass transition teleported speed to its lower limit")
    await _step_frames(600, 1.0)
    _check(controller.speed_mps < 18.15 and controller.speed_mps > 10.0, "Grass surface did not gradually reduce attainable speed")
    var parked_position := car.position
    var parked_rotation := car.rotation
    var parked_velocity := car.velocity
    var parked_speed: float = controller.speed_mps
    var parked_odometer: float = controller.odometer_m
    await _step_frames(30, 1.0, 1.0, false)
    _check(car.position == parked_position and car.rotation == parked_rotation and car.velocity == parked_velocity, "Unloaded collision changed vehicle physics")
    _check(controller.speed_mps == parked_speed and controller.odometer_m == parked_odometer, "Unloaded collision advanced driving state")
    controller.reset_motion()
    controller.occupied = false
    await _step_frames(30, 1.0, 1.0)
    _check(controller.speed_mps == 0.0 and controller.gear_label() == "P", "Empty vehicle accepted driving input")
    print("YARDMAN_VEHICLE_TEST %s acceleration_kmh=%.1f braking=1 reverse=1 steering=1 grass=1 freeze=1 reference_model=%s triangles=%d textured_surfaces=%d" % ["PASS" if failures == 0 else "FAIL", acceleration_speed * 3.6, reference_model, reference_triangles, reference_textured_surfaces])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
