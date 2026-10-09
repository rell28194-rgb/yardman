extends RefCounted
class_name YardmanVehicleController

var body: CharacterBody3D
var speed_mps := 0.0
var odometer_m := 0.0
var occupied := true
var _steer := 0.0

func configure(vehicle: CharacterBody3D) -> void:
    body = vehicle
    body.floor_snap_length = 0.8
    body.floor_max_angle = deg_to_rad(55.0)

func step(delta: float, throttle: float, turn: float, ready: bool) -> void:
    if body == null or not ready:
        return
    throttle = clampf(throttle, -1.0, 1.0) if occupied else 0.0
    turn = clampf(turn, -1.0, 1.0) if occupied else 0.0
    var desired := throttle * (12.0 if throttle < 0.0 else 34.0)
    var acceleration := 8.0 if absf(throttle) > 0.01 else 2.6
    if throttle < 0.0 and speed_mps > 0.6:
        desired = 0.0
        acceleration = 18.0
    speed_mps = move_toward(speed_mps, desired, delta * acceleration)
    _steer = move_toward(_steer, turn, delta * 4.0)
    if absf(speed_mps) > 0.15:
        body.rotate_y(-_steer * delta * clampf(absf(speed_mps) / 14.0, 0.1, 1.1) * signf(speed_mps))
    var forward := -body.global_transform.basis.z
    body.velocity.x = forward.x * speed_mps
    body.velocity.z = forward.z * speed_mps
    body.velocity.y = -1.0 if body.is_on_floor() else body.velocity.y - 22.0 * delta
    var before := body.global_position
    body.move_and_slide()
    odometer_m += Vector2(body.global_position.x - before.x, body.global_position.z - before.z).length()
    if body.is_on_wall():
        speed_mps = Vector2(body.velocity.x, body.velocity.z).dot(Vector2(forward.x, forward.z))
    var visual := body.get_node_or_null("VisualRig") as Node3D
    if visual != null and body.is_on_floor():
        var up := body.get_floor_normal()
        var ahead := forward.slide(up).normalized()
        if ahead.length_squared() > 0.01:
            var desired_basis := body.global_basis.inverse() * Basis.looking_at(ahead, up)
            visual.basis = visual.basis.slerp(desired_basis, clampf(delta * 6.0, 0.0, 1.0)).orthonormalized()

func reset_motion() -> void:
    speed_mps = 0.0
    _steer = 0.0
    if body != null:
        body.velocity = Vector3.ZERO
