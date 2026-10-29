extends Node3D
class_name YardmanFleetVehicleModel

const References = preload("res://scripts/reference_assets.gd")

const SOURCE_SEMANTIC_NODE_NAMES := {
    "engine": "Engine",
    "exhaust": "Exhaust",
    "pop_exhaust": "PopExhaust",
    "driver_root": "DriverRoot",
    "driver_assist": "DriverAssPoint",
    "under_roof": "UnderRoofPoint",
    "camera_front": "FrontCameraPoint",
    "camera_rear": "RearCameraPoint",
    "camera_follow": "FollowCameraPoint",
    "camera_hood": "HoodCameraPoint",
    "camera_side": "SideCameraPoint",
    "camera_wheel": "WheelCameraPoint",
    "camera_bumper": "BumperCameraPoint",
    "body_high": "BodyH",
    "body_low": "BodyL",
    "interior_high": "HD_interior",
    "interior_low": "LD_interior",
    "steering_high": "HD_steering_wheel",
    "steering_low": "LD_steering_wheel",
    "glass": "Glass",
    "stoplight": "ToyotaSupraRZ - Stoplights",
    "collision_root": "Colliders",
    "obstacle": "Obstacle",
    "wheel_particles": "WheelsParticles",
}

var shell: Node3D
var front_pivots: Array[Node3D] = []
var wheels: Array[Node3D] = []
var source_semantics: Dictionary = {}
var is_reference_model := false
var wheelbase_m := 2.60
var wheel_radius_m := 0.34
var geometry_bounds := AABB(Vector3(-0.925, 0.0, -2.2), Vector3(1.85, 1.35, 4.4))
var _wheel_rotation := 0.0
var _shell_rest_position := Vector3.ZERO
var _shell_rest_rotation := Vector3.ZERO
var _wheel_rest_rotations: Dictionary = {}
var _front_rest_rotations: Dictionary = {}

func build(hero_scene_filename: String) -> void:
    if hero_scene_filename.is_empty():
        set_meta("yardman_hero_asset_missing_or_invalid", true)
        return
    # Fleet identities must resolve to the exact private-pack filename. The
    # accepted Crown runtime deliberately aliases road_car.glb to Crown007, so
    # going through References.scene() here would make the Chaser masquerade as
    # the Crown. Fleet loading bypasses that alias and fails closed instead.
    var packed := _load_exact_private_scene(hero_scene_filename)
    if packed == null:
        set_meta("yardman_requested_hero_scene", hero_scene_filename)
        set_meta("yardman_hero_asset_missing_or_invalid", true)
        return
    var instance = packed.instantiate()
    if not instance is Node3D:
        if instance != null:
            instance.free()
        set_meta("yardman_hero_asset_missing_or_invalid", true)
        return
    var imported := instance as Node3D
    var bounds := _measure_mesh_bounds(imported)
    if not _bounds_are_valid(bounds):
        imported.free()
        set_meta("yardman_hero_asset_missing_or_invalid", true)
        return
    add_child(imported)
    shell = imported.find_child("BodyShell", true, false) as Node3D
    if shell == null:
        shell = imported
    geometry_bounds = bounds
    _shell_rest_position = shell.position
    _shell_rest_rotation = shell.rotation
    _bind_wheels(imported)
    _bind_source_semantics(imported)
    is_reference_model = true
    set_meta("yardman_dedicated_vehicle_mesh", true)
    set_meta("yardman_requested_hero_scene", hero_scene_filename)
    print("YARDMAN_FLEET_VEHICLE asset=%s bounds_m=%s wheelbase_m=%.3f wheels=%d source_semantics=%d" % [hero_scene_filename, geometry_bounds.size, wheelbase_m, wheels.size(), source_semantics.size()])

func _load_exact_private_scene(filename: String) -> PackedScene:
    if filename.is_empty() or filename.contains("/") or filename.contains("\\") or filename.contains(".."):
        return null
    if filename.get_extension().to_lower() not in ["glb", "gltf"]:
        return null
    var manifest := References.manifest()
    if manifest.is_empty() or int(manifest.get("format_version", 0)) != 1:
        return null
    var matched: Dictionary = {}
    var match_count := 0
    for raw_record in manifest.get("files", []):
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record
        if str(record.get("path", "")) != filename:
            continue
        matched = record
        match_count += 1
    if match_count != 1:
        return null
    var expected_sha := str(matched.get("sha256", "")).to_lower()
    if expected_sha.length() != 64:
        return null

    # The owner APK cannot export res://.godot/imported directly because Godot
    # excludes dot-prefixed project folders. The export manifest generator saves
    # each validated imported vehicle as a bundled PackedScene under an ordinary
    # project path. Prefer that signed, export-visible scene whenever present.
    var packaged := References.packaged_scene_path(filename)
    if not packaged.is_empty() and ResourceLoader.exists(packaged):
        return ResourceLoader.load(packaged) as PackedScene

    var path := References.exact_asset_path(filename)
    if path.is_empty():
        return null

    # Downloaded owner media never gets trusted merely because it exists.
    # Verify the exact manifest digest and byte count before runtime glTF import.
    if path.begins_with("user://"):
        if FileAccess.get_sha256(path).to_lower() != expected_sha:
            return null
        if matched.has("bytes"):
            var downloaded := FileAccess.open(path, FileAccess.READ)
            if downloaded == null or int(downloaded.get_length()) != int(matched.get("bytes", -1)):
                return null
        return _load_runtime_gltf(path)

    if not ResourceLoader.exists(path):
        return null
    # Development/private preflight has the source bytes, so enforce the pack
    # manifest byte-for-byte. Android exports use the packaged scene above;
    # source imports remain the authority used to generate that signed scene.
    if not OS.has_feature("template") and FileAccess.file_exists(path):
        if FileAccess.get_sha256(path).to_lower() != expected_sha:
            return null
        if matched.has("bytes"):
            var handle := FileAccess.open(path, FileAccess.READ)
            if handle == null or int(handle.get_length()) != int(matched.get("bytes", -1)):
                return null
    return ResourceLoader.load(path) as PackedScene

func _load_runtime_gltf(path: String) -> PackedScene:
    var state := GLTFState.new()
    var document := GLTFDocument.new()
    var absolute_path := ProjectSettings.globalize_path(path)
    var err := document.append_from_file(absolute_path, state, 0, absolute_path.get_base_dir())
    if err != OK:
        return null
    var generated := document.generate_scene(state)
    if not generated is Node3D:
        if generated != null:
            generated.free()
        return null
    var packed := PackedScene.new()
    if packed.pack(generated) != OK:
        generated.free()
        return null
    generated.free()
    return packed

func _bind_wheels(imported: Node3D) -> void:
    front_pivots.clear()
    wheels.clear()
    _wheel_rest_rotations.clear()
    _front_rest_rotations.clear()

    var conventions := [
        {
            "name": "yardman_generated",
            "pivots": ["FrontWheelLeft", "FrontWheelRight", "RearWheelLeft", "RearWheelRight"],
            "spins": ["FrontWheelLeftSpin", "FrontWheelRightSpin", "RearWheelLeftSpin", "RearWheelRightSpin"],
        },
        {
            # Preferred source-complete contract. Original CarX steering roots
            # remain intact while private scene reconstruction inserts dedicated
            # spin helpers. Calipers can therefore steer without spinning.
            "name": "carx_source_reanchored",
            "pivots": ["WheelFL", "WheelFR", "WheelRL", "WheelRR"],
            "spins": ["WheelFLSpin", "WheelFRSpin", "WheelRLSpin", "WheelRRSpin"],
        },
        {
            # Transitional fallback for source scenes that preserve the original
            # wheel roots but have not yet separated tyre/rim spin geometry.
            "name": "carx_source_direct",
            "pivots": ["WheelFL", "WheelFR", "WheelRL", "WheelRR"],
            "spins": ["WheelFL", "WheelFR", "WheelRL", "WheelRR"],
        },
    ]

    for convention in conventions:
        var pivots: Array[Node3D] = []
        var spins: Array[Node3D] = []
        var pivot_names: Array = convention["pivots"]
        var spin_names: Array = convention["spins"]
        var complete := true
        for index in range(4):
            var pivot := imported.find_child(str(pivot_names[index]), true, false) as Node3D
            var spin := imported.find_child(str(spin_names[index]), true, false) as Node3D
            if pivot == null or spin == null:
                complete = false
                break
            pivots.append(pivot)
            spins.append(spin)
        if not complete:
            continue

        front_pivots.assign([pivots[0], pivots[1]])
        wheels.assign(spins)
        for pivot in front_pivots:
            _front_rest_rotations[pivot.get_instance_id()] = pivot.rotation
        for spin in wheels:
            _wheel_rest_rotations[spin.get_instance_id()] = spin.rotation

        var front_z := _relative_pose(pivots[0]).origin.z
        var rear_z := _relative_pose(pivots[2]).origin.z
        wheelbase_m = clampf(absf(front_z - rear_z), 1.8, 4.5)
        var tyre_bounds := _measure_mesh_bounds(spins[0])
        if tyre_bounds.size.length_squared() > 0.01:
            wheel_radius_m = clampf(maxf(tyre_bounds.size.y, tyre_bounds.size.z) * 0.5, 0.20, 0.65)
        set_meta("yardman_wheel_binding_convention", str(convention["name"]))
        set_meta("yardman_wheel_binding_complete", true)
        return

    set_meta("yardman_wheel_binding_convention", "unresolved")
    set_meta("yardman_wheel_binding_complete", false)

func _bind_source_semantics(imported: Node3D) -> void:
    source_semantics.clear()
    for role in SOURCE_SEMANTIC_NODE_NAMES:
        var source_name := str(SOURCE_SEMANTIC_NODE_NAMES[role])
        var node := imported.find_child(source_name, true, false) as Node3D
        if node == null:
            continue
        source_semantics[str(role)] = get_path_to(node)
    set_meta("yardman_source_semantics", source_semantics.duplicate())
    set_meta("yardman_source_semantic_count", source_semantics.size())

func semantic_node(role: String) -> Node3D:
    if not source_semantics.has(role):
        return null
    return get_node_or_null(source_semantics[role]) as Node3D

func update_motion(delta: float, speed: float, steering: float, braking: float, reversing: bool, running: bool, pitch: float, roll: float) -> void:
    if shell == null:
        return
    if not wheels.is_empty():
        _wheel_rotation = fmod(_wheel_rotation - speed * delta / maxf(wheel_radius_m, 0.20), TAU)
        for wheel in wheels:
            var rest: Vector3 = _wheel_rest_rotations.get(wheel.get_instance_id(), wheel.rotation)
            var rotation := wheel.rotation
            rotation.x = rest.x + _wheel_rotation
            wheel.rotation = rotation
        for pivot in front_pivots:
            var rest: Vector3 = _front_rest_rotations.get(pivot.get_instance_id(), pivot.rotation)
            var rotation := pivot.rotation
            rotation.y = rest.y + steering
            pivot.rotation = rotation
    var response := 1.0 - exp(-delta * 8.0)
    shell.rotation.x = lerpf(shell.rotation.x, _shell_rest_rotation.x + pitch, response)
    shell.rotation.z = lerpf(shell.rotation.z, _shell_rest_rotation.z + roll, response)
    shell.position.y = lerpf(shell.position.y, _shell_rest_position.y - minf(absf(roll) * 0.12, 0.018), response)

func _relative_pose(node: Node3D) -> Transform3D:
    var pose := node.transform
    var parent: Node = node.get_parent()
    while parent != null and parent != self:
        if parent is Node3D:
            pose = (parent as Node3D).transform * pose
        parent = parent.get_parent()
    return pose

func _collect_meshes(node: Node, parent_pose: Transform3D, result: Array[Dictionary]) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose *= (node as Node3D).transform
    if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
        result.append({"instance": node, "pose": pose})
    for child in node.get_children():
        _collect_meshes(child, pose, result)

func _measure_mesh_bounds(node: Node3D) -> AABB:
    var entries: Array[Dictionary] = []
    _collect_meshes(node, Transform3D.IDENTITY, entries)
    var combined := AABB()
    var first := true
    for entry in entries:
        var instance: MeshInstance3D = entry["instance"]
        var pose: Transform3D = entry["pose"]
        var bounds: AABB = pose * instance.mesh.get_aabb()
        combined = bounds if first else combined.merge(bounds)
        first = false
    return combined

func _bounds_are_valid(bounds: AABB) -> bool:
    var size := bounds.size
    return is_finite(size.x) and is_finite(size.y) and is_finite(size.z) \
        and size.x >= 0.8 and size.x <= 4.5 \
        and size.y >= 0.35 and size.y <= 4.5 \
        and size.z >= 1.8 and size.z <= 12.0
