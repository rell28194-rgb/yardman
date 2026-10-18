extends SceneTree

const Canvas = preload("res://scripts/parish_map_canvas.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PARISH_MAP_RUNTIME_TEST: " + message)

func _run() -> void:
    var bounds := [0.0, 0.0, 200.0, 100.0]
    var area := Rect2(10.0, 20.0, 400.0, 200.0)
    _check(Canvas.world_to_canvas(Vector2(0.0, 0.0), bounds, area).is_equal_approx(Vector2(10.0, 20.0)), "map projection moved north-west corner")
    _check(Canvas.world_to_canvas(Vector2(200.0, 100.0), bounds, area).is_equal_approx(Vector2(410.0, 220.0)), "map projection moved south-east corner")
    _check(Canvas.world_to_canvas(Vector2(100.0, 50.0), bounds, area).is_equal_approx(Vector2(210.0, 120.0)), "map projection did not preserve centre")

    var canvas = Canvas.new()
    canvas.size = Vector2(800.0, 500.0)
    root.add_child(canvas)
    canvas.configure({
        "bounds": bounds,
        "current_parish": "Kingston",
        "authority": "test",
        "parishes": {
            "Kingston": [{"bounds": [0.0, 0.0, 100.0, 100.0], "rings": [[[0.0, 0.0], [100.0, 0.0], [100.0, 100.0], [0.0, 100.0], [0.0, 0.0]]]}],
            "St. Andrew": [{"bounds": [100.0, 0.0, 200.0, 100.0], "rings": [[[100.0, 0.0], [200.0, 0.0], [200.0, 100.0], [100.0, 100.0], [100.0, 0.0]]]}],
        },
    })
    await process_frame
    _check(canvas.parish_count() == 2, "canvas lost parish-only geometry")
    _check(canvas.current_parish == "Kingston", "canvas did not receive current-parish highlight")
    canvas.set_current_parish("St. Andrew")
    _check(canvas.current_parish == "St. Andrew", "live current-parish highlight did not update")
    canvas.configure({})
    _check(canvas.parish_count() == 0, "empty build retained stale map geometry")

    canvas.queue_free()
    await process_frame
    print("YARDMAN_PARISH_MAP_RUNTIME_TEST %s aspect_fit=1 parish_only=1 live_highlight=1" % ["PASS" if failures == 0 else "FAIL"])
    quit(0 if failures == 0 else 1)
