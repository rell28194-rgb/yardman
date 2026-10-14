extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const CameraRuntime = preload("res://scripts/vehicle_camera_runtime.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_CAMERA_TEST: " + message)

func _run() -> void:
    var distances: Array[float] = []
    var heights: Array[float] = []
    for vehicle_id in Catalog.production_ids():
        var style := CameraRuntime.exterior_profile(vehicle_id)
        var catalog := Catalog.profile(vehicle_id)
        _check(str(style.vehicle_id) == vehicle_id, "%s camera profile identity mismatch" % vehicle_id)
        _check(is_equal_approx(float(style.distance_m), float(catalog.camera_distance_m)), "%s camera ignored catalog distance" % vehicle_id)
        _check(float(style.height_m) > 1.20 and float(style.height_m) < 1.70, "%s camera height outside chase envelope" % vehicle_id)
        _check(CameraRuntime.target_fov(vehicle_id, 50.0, false) > CameraRuntime.target_fov(vehicle_id, 0.0, false), "%s speed did not widen FOV" % vehicle_id)
        _check(is_equal_approx(CameraRuntime.target_fov(vehicle_id, 50.0, true), float(style.fov_base)), "%s reduced motion did not suppress speed FOV" % vehicle_id)
        distances.append(float(style.distance_m))
        heights.append(float(style.height_m))

    _check(distances[0] != distances[1] and distances[1] != distances[2] and distances[0] != distances[2], "production cars still share one chase distance")
    _check(heights.max() - heights.min() >= 0.15, "production camera heights are not materially distinct")

    print("YARDMAN_VEHICLE_CAMERA_TEST %s vehicles=%d distinct_chase_profiles=1" % ["PASS" if failures == 0 else "FAIL", Catalog.production_ids().size()])
    quit(0 if failures == 0 else 1)
