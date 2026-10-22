extends Node
class_name YardmanBeta1VehicleDriverRuntime

# Optional owner-private presentation layer. Provenance for the recovered
# HighwayDriver already records a Godot 4.7.2 combined sedan+driver fit.
# This runtime does not replace the on-foot player and never owns collision.
const References = preload("res://scripts/reference_assets.gd")
const DRIVER_ASSET := "road_driver_seated.glb"
const DRIVER_FIT_POSITION := Vector3(0.91, 0.21, -0.187)
const DRIVER_FIT_ROTATION := Vector3.ZERO
const DRIVER_FIT_SCALE := Vector3.ONE
const POLL_INTERVAL := 0.12

var _driver: Node3D
var _clock := 0.0
var _attached := false

func _ready() -> void:
    set_process(true)
    call_deferred("_try_attach")

func _process(delta: float) -> void:
    _clock += delta
    if _clock < POLL_INTERVAL:
        return
    _clock = 0.0
    if not _attached:
        _try_attach()
    _sync_visibility()

func _try_attach() -> void:
    if _attached:
        return
    var root := get_parent()
    if root == null:
        return
    var car := root.get_node_or_null("RoadQA") as Node3D
    if car == null:
        return
    var visual := car.get_node_or_null("VisualRig") as Node3D
    if visual == null or not bool(visual.get("is_reference_model")):
        return
    var packed: PackedScene = References.scene(DRIVER_ASSET)
    if packed == null:
        # Missing private media is an accepted source-only/public-CI fallback.
        set_process(false)
        return
    var driver := packed.instantiate() as Node3D
    if driver == null:
        set_process(false)
        return
    driver.name = "RecoveredSeatedDriver"
    driver.position = DRIVER_FIT_POSITION
    driver.rotation = DRIVER_FIT_ROTATION
    driver.scale = DRIVER_FIT_SCALE
    driver.set_meta("reference_asset", DRIVER_ASSET)
    driver.set_meta("presentation_only", true)
    driver.set_meta("on_foot_replacement", false)
    driver.set_meta("collision", false)
    # Fail closed if a future source revision unexpectedly imports physics.
    for node in driver.find_children("*", "CollisionObject3D", true, false):
        var body := node as CollisionObject3D
        if body != null:
            body.collision_layer = 0
            body.collision_mask = 0
    visual.add_child(driver)
    _driver = driver
    _attached = true
    _sync_visibility()

func _sync_visibility() -> void:
    if _driver == null or not is_instance_valid(_driver):
        return
    var root := get_parent()
    var player := root.get_node_or_null("Player") if root != null else null
    _driver.visible = bool(player.get("in_vehicle")) if player != null else true

static func driver_contract() -> Dictionary:
    return {
        "file": DRIVER_ASSET,
        "position_m": DRIVER_FIT_POSITION,
        "rotation_rad": DRIVER_FIT_ROTATION,
        "scale": DRIVER_FIT_SCALE,
        "source_vertices": 3986,
        "source_triangles": 6066,
        "source_bones": 60,
        "static_seated_pose": true,
        "combined_sedan_driver_render": true,
        "visibility_follows_occupancy": true,
        "collision": false,
        "on_foot_replacement": false,
        "asset_absent_fallback": true,
    }
