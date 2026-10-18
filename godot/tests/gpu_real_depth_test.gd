extends SceneTree

const DepthEffect = preload("res://scripts/gpu_depth_capture_effect.gd")
const INITIAL_SIZE := Vector2i(320, 180)
const RESIZED_SIZE := Vector2i(256, 144)
const SNAPSHOT_TIMEOUT_FRAMES := 180
const RELEASE_TIMEOUT_FRAMES := 120

var failures := 0
var _viewport: SubViewport
var _camera: Camera3D
var _occluder: MeshInstance3D
var _effect: CompositorEffect

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_REAL_DEPTH_TEST: " + message)

func _run() -> void:
    _build_scene()
    for _frame in range(8):
        await process_frame

    var first := await _snapshot()
    _validate_snapshot(first, INITIAL_SIZE, 7.5, "initial")

    _occluder.position.z = -12.0
    for _frame in range(4):
        await process_frame
    var moved := await _snapshot()
    _validate_snapshot(moved, INITIAL_SIZE, 11.5, "moved")
    var first_center := _sample_linear(first, INITIAL_SIZE.x / 2, INITIAL_SIZE.y / 2)
    var moved_center := _sample_linear(moved, INITIAL_SIZE.x / 2, INITIAL_SIZE.y / 2)
    _check(moved_center > first_center + 3.0,
        "captured depth did not react to real scene geometry motion")

    _viewport.size = RESIZED_SIZE
    for _frame in range(5):
        await process_frame
    var resized := await _snapshot()
    _validate_snapshot(resized, RESIZED_SIZE, 11.5, "resized")
    _check(int(resized.get("buffer_reallocations", 0)) >= 2,
        "depth capture buffer did not reallocate after viewport resize")

    await _cleanup()
    print("YARDMAN_GPU_REAL_DEPTH_TEST %s reverse_z=1 linearization=1 geometry_motion=1 resize=1 cleanup=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _build_scene() -> void:
    _viewport = SubViewport.new()
    _viewport.name = "HZBDepthValidationViewport"
    _viewport.size = INITIAL_SIZE
    _viewport.own_world_3d = true
    _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    _viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
    get_root().add_child(_viewport)

    var world := Node3D.new()
    _viewport.add_child(world)

    _camera = Camera3D.new()
    _camera.name = "DepthValidationCamera"
    _camera.fov = 70.0
    _camera.near = 0.1
    _camera.far = 100.0
    _camera.current = true
    world.add_child(_camera)

    _effect = DepthEffect.new()
    var compositor := Compositor.new()
    var effects: Array[CompositorEffect] = [_effect]
    compositor.compositor_effects = effects
    _camera.compositor = compositor

    var box := BoxMesh.new()
    box.size = Vector3(4.0, 4.0, 1.0)
    _occluder = MeshInstance3D.new()
    _occluder.name = "KnownDepthBox"
    _occluder.mesh = box
    _occluder.position = Vector3(0.0, 0.0, -8.0)
    world.add_child(_occluder)

func _snapshot() -> Dictionary:
    _effect.request_snapshot()
    var frames := 0
    while not _effect.snapshot_ready() and frames < SNAPSHOT_TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(_effect.snapshot_ready(), "depth compositor snapshot timed out")
    return _effect.take_snapshot() if _effect.snapshot_ready() else {}

func _validate_snapshot(snapshot: Dictionary, expected_size: Vector2i,
        expected_center_depth: float, label: String) -> void:
    _check(snapshot.get("size", Vector2i.ZERO) == expected_size,
        "%s snapshot internal size mismatch" % label)
    var values: PackedFloat32Array = snapshot.get("values", PackedFloat32Array())
    _check(values.size() == expected_size.x * expected_size.y * 2,
        "%s snapshot buffer size mismatch" % label)
    if values.size() != expected_size.x * expected_size.y * 2:
        return

    var center_x := expected_size.x / 2
    var center_y := expected_size.y / 2
    var center_raw := _sample_raw(snapshot, center_x, center_y)
    var center_linear := _sample_linear(snapshot, center_x, center_y)
    var background_raw := _sample_raw(snapshot, 8, 8)
    var background_linear := _sample_linear(snapshot, 8, 8)
    var z_far := float(snapshot.get("z_far", 0.0))
    var z_near := float(snapshot.get("z_near", 0.0))

    _check(center_raw > background_raw + 0.0001,
        "%s depth buffer does not exhibit Godot reverse-Z ordering" % label)
    _check(absf(center_linear - expected_center_depth) <= 0.65,
        "%s inverse-projection linear depth differs from known box front face: got %.4f expected %.4f" % [
            label, center_linear, expected_center_depth])
    _check(background_linear >= z_far * 0.96,
        "%s background did not linearize near the far plane" % label)
    _check(z_near >= 0.099 and z_near <= 0.101,
        "%s camera near plane changed unexpectedly" % label)
    _check(z_far >= 99.9 and z_far <= 100.1,
        "%s camera far plane changed unexpectedly" % label)
    _check(int(snapshot.get("frames_captured", 0)) > 0,
        "%s compositor never captured a rendered frame" % label)

func _sample_raw(snapshot: Dictionary, x: int, y: int) -> float:
    var size: Vector2i = snapshot.get("size", Vector2i.ZERO)
    var values: PackedFloat32Array = snapshot.get("values", PackedFloat32Array())
    if size.x <= 0 or values.is_empty():
        return -1.0
    return values[(y * size.x + x) * 2]

func _sample_linear(snapshot: Dictionary, x: int, y: int) -> float:
    var size: Vector2i = snapshot.get("size", Vector2i.ZERO)
    var values: PackedFloat32Array = snapshot.get("values", PackedFloat32Array())
    if size.x <= 0 or values.is_empty():
        return -1.0
    return values[(y * size.x + x) * 2 + 1]

func _cleanup() -> void:
    if _camera != null:
        _camera.compositor = null
    await process_frame
    await process_frame
    _effect.release_resources()
    var frames := 0
    while not _effect.release_done() and frames < RELEASE_TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(_effect.release_done(), "depth compositor render resources did not release")
    if _viewport != null:
        _viewport.queue_free()
    await process_frame
    RenderingServer.force_sync()
    await process_frame
