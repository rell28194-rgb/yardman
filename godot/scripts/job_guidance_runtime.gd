extends Node
class_name YardmanJobGuidanceRuntime

const UPDATE_INTERVAL := 0.16
const MARKER_DISTANCE_M := 1800.0

var _clock := 0.0
var _layer: CanvasLayer
var _label: Label
var _marker: Node3D
var _marker_scene_id := 0
var _last_state: Dictionary = {}

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()

func _process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    var scene := get_tree().current_scene
    var jobs := get_node_or_null("/root/JobRuntime")
    if scene == null or jobs == null:
        _hide_guidance()
        return
    var job_value = jobs.get("active_job")
    if not job_value is Dictionary or job_value.is_empty():
        _hide_guidance()
        return
    var roads = scene.get("roads")
    var terrain = scene.get("terrain")
    var player = scene.get("player")
    var car = scene.get("car")
    if roads == null or terrain == null or player == null or car == null:
        _hide_guidance()
        return
    var active: Node3D = car if bool(player.get("in_vehicle")) else player
    var world_value = roads.call("local_to_world", active.position)
    if not world_value is PackedFloat64Array or world_value.size() < 3:
        _hide_guidance()
        return
    var current := Vector2(float(world_value[0]), float(world_value[2]))
    var job: Dictionary = job_value
    var destination := Vector2(float(job.get("destination_x", current.x)), float(job.get("destination_z", current.y)))
    var heading := float(scene.get("camera_yaw"))
    var state := guidance_state(current, destination, heading)
    _last_state = state
    _label.visible = true
    _label.text = "NAV %s  •  %.1f km" % [str(state.turn), float(state.distance_m) / 1000.0]

    _ensure_marker(scene)
    var marker_visible := float(state.distance_m) <= MARKER_DISTANCE_M and bool(terrain.call("is_world_position_ready", destination.x, destination.y))
    if _marker != null:
        _marker.visible = marker_visible
        if marker_visible:
            var ground := float(terrain.call("height_at", destination.x, destination.y))
            if is_finite(ground):
                _marker.position = roads.call("world_to_local", destination.x, destination.y, ground)
            else:
                _marker.visible = false

static func guidance_state(current: Vector2, destination: Vector2, camera_yaw: float) -> Dictionary:
    var offset := destination - current
    var distance := offset.length()
    if distance < 0.001:
        return {"distance_m": 0.0, "bearing_delta_rad": 0.0, "bearing_delta_deg": 0.0, "turn": "ARRIVED"}
    var target_yaw := atan2(-offset.x, -offset.y)
    var delta := wrapf(target_yaw - camera_yaw, -PI, PI)
    var degrees := rad_to_deg(delta)
    var magnitude := absf(degrees)
    var turn := "AHEAD"
    if magnitude >= 157.5:
        turn = "BEHIND"
    elif magnitude >= 22.5:
        turn = "LEFT" if degrees > 0.0 else "RIGHT"
    return {"distance_m": distance, "bearing_delta_rad": delta, "bearing_delta_deg": degrees, "turn": turn}

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.name = "YardmanJobGuidanceUI"
    _layer.layer = 23
    add_child(_layer)
    _label = Label.new()
    _label.name = "JobGuidanceLabel"
    _label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _label.set_anchors_preset(Control.PRESET_CENTER_TOP)
    _label.position = Vector2(-190.0, 90.0)
    _label.size = Vector2(380.0, 30.0)
    _label.visible = false
    _layer.add_child(_label)

func _ensure_marker(scene: Node) -> void:
    var scene_id := scene.get_instance_id()
    if _marker != null and is_instance_valid(_marker) and _marker_scene_id == scene_id and _marker.get_parent() == scene:
        return
    if _marker != null and is_instance_valid(_marker):
        _marker.queue_free()
    _marker_scene_id = scene_id
    _marker = Node3D.new()
    _marker.name = "CourierDestinationBeacon"
    scene.add_child(_marker)

    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.92, 0.52, 0.04)
    material.emission_enabled = true
    material.emission = Color(1.0, 0.47, 0.025)
    material.emission_energy_multiplier = 2.4
    material.roughness = 0.38

    var pole_mesh := CylinderMesh.new()
    pole_mesh.top_radius = 0.16
    pole_mesh.bottom_radius = 0.16
    pole_mesh.height = 8.0
    pole_mesh.radial_segments = 8
    var pole := MeshInstance3D.new()
    pole.name = "BeaconPole"
    pole.mesh = pole_mesh
    pole.position.y = 4.0
    pole.material_override = material
    pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _marker.add_child(pole)

    var ring_mesh := TorusMesh.new()
    ring_mesh.inner_radius = 0.70
    ring_mesh.outer_radius = 0.88
    ring_mesh.rings = 8
    ring_mesh.ring_segments = 12
    var ring := MeshInstance3D.new()
    ring.name = "BeaconRing"
    ring.mesh = ring_mesh
    ring.position.y = 0.12
    ring.material_override = material
    ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _marker.add_child(ring)
    _marker.visible = false

func _hide_guidance() -> void:
    _last_state.clear()
    if _label != null:
        _label.visible = false
    if _marker != null and is_instance_valid(_marker):
        _marker.visible = false

func runtime_snapshot() -> Dictionary:
    return {
        "active": not _last_state.is_empty(),
        "turn": str(_last_state.get("turn", "")),
        "distance_m": float(_last_state.get("distance_m", 0.0)),
        "marker_visible": _marker != null and is_instance_valid(_marker) and _marker.visible,
    }
