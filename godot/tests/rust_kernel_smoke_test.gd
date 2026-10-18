extends SceneTree

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RUST_KERNEL_SMOKE_TEST: " + message)

func _gdscript_filter(points: PackedVector2Array, center: Vector2, radius: float) -> PackedInt32Array:
    var out := PackedInt32Array()
    if radius < 0.0:
        return out
    var radius_sq := radius * radius
    for index in range(points.size()):
        if points[index].distance_squared_to(center) <= radius_sq:
            out.append(index)
    return out

func _gdscript_count(points: PackedVector2Array, center: Vector2, radius: float) -> int:
    if radius < 0.0:
        return 0
    var radius_sq := radius * radius
    var count := 0
    for point in points:
        if point.distance_squared_to(center) <= radius_sq:
            count += 1
    return count

func _run() -> void:
    _check(ClassDB.class_exists(&"YardmanRustKernels"), "Rust GDExtension class was not registered")
    if failures != 0:
        quit(1)
        return

    var kernel = ClassDB.instantiate(&"YardmanRustKernels")
    _check(kernel != null, "Could not instantiate YardmanRustKernels")
    if kernel == null:
        quit(1)
        return
    _check(str(kernel.call("build_id")) == "yardman-rust/api-4.7/core-v1", "Unexpected Rust build identity")

    const POINT_COUNT := 120000
    var points := PackedVector2Array()
    points.resize(POINT_COUNT)
    for index in range(POINT_COUNT):
        var x := float((index * 73) % 4096) - 2048.0
        var y := float((index * 193) % 4096) - 2048.0
        points[index] = Vector2(x, y)

    var center := Vector2(117.5, -284.25)
    var radius := 930.0
    var expected := _gdscript_filter(points, center, radius)
    var native: PackedInt32Array = kernel.call("filter_points_in_radius", points, center, radius)
    _check(native == expected, "Rust radius filter differs from GDScript reference")
    _check(int(kernel.call("count_points_in_radius", points, center, radius)) == expected.size(), "Rust count differs from reference filter")
    _check((kernel.call("filter_points_in_radius", points, center, -1.0) as PackedInt32Array).is_empty(), "Negative radius must fail closed")

    const LOOPS := 8
    var rust_started := Time.get_ticks_usec()
    var rust_checksum := 0
    for iteration in range(LOOPS):
        rust_checksum += int(kernel.call("count_points_in_radius", points, center + Vector2(iteration, -iteration), radius))
    var rust_us := Time.get_ticks_usec() - rust_started

    var gd_started := Time.get_ticks_usec()
    var gd_checksum := 0
    for iteration in range(LOOPS):
        gd_checksum += _gdscript_count(points, center + Vector2(iteration, -iteration), radius)
    var gd_us := Time.get_ticks_usec() - gd_started
    _check(rust_checksum == gd_checksum, "Benchmark paths produced different results")

    if failures == 0:
        var ratio := float(gd_us) / float(maxi(rust_us, 1))
        print("YARDMAN_RUST_KERNEL_SMOKE PASS points=%d loops=%d rust_us=%d gdscript_us=%d ratio=%.2f build=%s" % [
            POINT_COUNT, LOOPS, rust_us, gd_us, ratio, str(kernel.call("build_id"))
        ])
    quit(0 if failures == 0 else 1)
