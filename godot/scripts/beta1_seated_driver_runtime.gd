extends Node
class_name YardmanBeta1SeatedDriverRuntime

# Owner-private recovered driver. This is presentation-only and binds only to
# the validated reference Crown visual. The measured combined-sedan fit is kept
# in vehicle-model space; physics, collision, handling and fleet state remain
# owned by their existing systems.
const References = preload("res://scripts/reference_assets.gd")
const DRIVER_ASSET := "road_driver_seated.glb"
const DRIVER_FIT_POSITION_M := Vector3(0.91, 0.21, -0.187)

var _vehicle_visual: Node3D
var _driver: Node3D
var _controller: Variant
var _bind_clock := 0.0

func _ready() -> void:
    call_deferred("_try_bind")

func _process(delta: float) -> void:
    if _driver != null and is_instance_valid(_driver):
        _driver.visible = _is_occupied()
        return
    _bind_clock += delta
    if _bind_clock >= 0.5:
        _bind_clock = 0.0
        _try_bind()

func _try_bind() -> void:
    if _driver != null and is_instance_valid(_driver):
        return
    var root := get_parent()
    if root == null:
        return
    _controller = root.get("vehicle")
    var car := root.get_node_or_null("RoadQA") as Node3D
    if car == null:
        return
    var visual := car.get_node_or_null("VisualRig") as Node3D
    if visual == null or not bool(visual.get("is_reference_model")):
        return
    var shell := visual.get("shell") as Node3D
    if shell == null or not visual.is_ancestor_of(shell):
        return
    var packed: PackedScene = References.scene(DRIVER_ASSET)
    if packed == null:
        # Public/source-only builds deliberately stay on the existing Crown.
        return
    var driver := packed.instantiate() as Node3D
    if driver == null:
        return

    # Preserve the recovered source root basis exactly; only the measured RHD
    # translation is supplied by Yardman's accepted combined-sedan fit.
    var source_basis := driver.transform.basis
    var shell_pose := relative_pose(shell, visual)
    shell.add_child(driver)
    driver.name = "RecoveredSeatedDriver"
    driver.transform = driver_local_pose(shell_pose, source_basis)
    driver.visible = _is_occupied()
    driver.set_meta("reference_asset", DRIVER_ASSET)
    driver.set_meta("measured_rhd_fit", true)
    driver.set_meta("collision", false)
    driver.set_meta("static_source_pose", true)
    driver.set_meta("animation_retarget_pending", true)
    driver.set_meta("android_acceptance_pending", true)
    _vehicle_visual = visual
    _driver = driver

func _is_occupied() -> bool:
    return _controller != null and bool(_controller.get("occupied"))

static func relative_pose(node: Node3D, ancestor: Node3D) -> Transform3D:
    if node == null or ancestor == null or not ancestor.is_ancestor_of(node):
        return Transform3D()
    var pose := node.transform
    var parent := node.get_parent()
    while parent != null and parent != ancestor:
        if parent is Node3D:
            pose = (parent as Node3D).transform * pose
        parent = parent.get_parent()
    return pose

static func driver_local_pose(shell_model_pose: Transform3D, source_basis: Basis = Basis.IDENTITY) -> Transform3D:
    return shell_model_pose.affine_inverse() * Transform3D(source_basis, DRIVER_FIT_POSITION_M)

static func asset_contract() -> Dictionary:
    return {
        "file": DRIVER_ASSET,
        "fit_position_m": DRIVER_FIT_POSITION_M,
        "fit_rotation_y_rad": 0.0,
        "fit_scale": 1.0,
        "requires_reference_crown": true,
        "visible_when_occupied": true,
        "collision": false,
        "physics_mutation": false,
        "handling_mutation": false,
        "fleet_mutation": false,
        "static_source_pose": true,
        "animation_retarget_pending": true,
        "android_acceptance_pending": true,
        "asset_absent_fallback": true,
    }
