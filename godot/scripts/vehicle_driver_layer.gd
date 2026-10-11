extends Node

# Optional private recovered driver. Public/source-only builds remain identical
# when road_driver_seated.glb is absent. This visual never changes collision,
# vehicle physics, navigation, or the player's on-foot rig.
const References = preload("res://scripts/reference_assets.gd")
const DRIVER_FILE := "road_driver_seated.glb"
const DRIVER_POSITION_M := Vector3(0.91, 0.21, -0.187)

var _driver: Node3D
var _player: Node
var _attempted := false

func _ready() -> void:
    set_process(true)

func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    if _player == null or not is_instance_valid(_player):
        _player = scene.get_node_or_null("Player")
    if _driver == null and not _attempted:
        var shell := scene.get_node_or_null("RoadQA/VisualRig/road_car/BodyShell") as Node3D
        if shell == null:
            # Imported GLB root naming may differ; use the actual runtime shell.
            var visual := scene.get_node_or_null("RoadQA/VisualRig") as Node3D
            if visual != null:
                shell = visual.find_child("BodyShell", true, false) as Node3D
        if shell != null:
            _attempted = true
            _attach(shell)
    if _driver != null:
        _driver.visible = _player != null and _player.get("in_vehicle") == true

func _attach(shell: Node3D) -> void:
    var packed := References.scene(DRIVER_FILE)
    if packed == null:
        return
    var instance := packed.instantiate() as Node3D
    if instance == null:
        push_warning("Yardman recovered driver could not instantiate; leaving sedan unoccupied visually")
        return
    instance.name = "RecoveredSeatedDriver"
    instance.position = DRIVER_POSITION_M
    instance.rotation = Vector3.ZERO
    instance.scale = Vector3.ONE
    instance.set_meta("source", "CarX Highway recovered seated rig")
    instance.set_meta("fit", "measured RHD sedan steering/cabin landmarks; no mirror/rescale")
    instance.set_meta("animation_state", "static source seated pose; animation retarget pending")
    shell.add_child(instance)
    _driver = instance

func debug_state() -> Dictionary:
    return {
        "attempted": _attempted,
        "attached": _driver != null,
        "visible": _driver.visible if _driver != null else false,
        "driver_file": DRIVER_FILE,
        "position_m": DRIVER_POSITION_M,
    }
