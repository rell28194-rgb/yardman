extends SceneTree

const CameraRuntime = preload("res://scripts/vehicle_camera_runtime.gd")

func _initialize() -> void:
    var crown: Dictionary = CameraRuntime.profile_for("toyota_crown")
    var sports: Dictionary = CameraRuntime.profile_for("audi_r8")
    var truck: Dictionary = CameraRuntime.profile_for("carx_truck_peterbilt")
    var compact: Dictionary = CameraRuntime.profile_for("carx_ae86_a")
    var default_style: Dictionary = CameraRuntime.profile_for("toyota_chaser_v")

    if str(crown.get("style", "")) != "crown_sedan":
        _fail("Crown profile missing")
        return
    if str(sports.get("style", "")) != "low_sports" or float(sports.distance_m) >= float(crown.distance_m):
        _fail("sports camera is not tighter than Crown")
        return
    if str(truck.get("style", "")) != "large_body" or float(truck.distance_m) <= 9.0:
        _fail("large-body camera distance missing")
        return
    if str(compact.get("style", "")) != "compact_drift":
        _fail("compact/drift profile missing")
        return
    if str(default_style.get("style", "")) != "default":
        _fail("default profile fallback missing")
        return

    var crown_base := CameraRuntime.target_fov(crown, 0.0, false)
    var crown_fast := CameraRuntime.target_fov(crown, 52.0, false)
    var reduced := CameraRuntime.target_fov(crown, 52.0, true)
    if crown_fast <= crown_base:
        _fail("speed-sensitive FOV did not increase")
        return
    if not is_equal_approx(reduced, crown_base):
        _fail("reduced-motion FOV should remain at base")
        return

    print("YARDMAN_VEHICLE_CAMERA_PRESENTATION_TEST PASS crown=1 sports=1 truck=1 compact=1 speed_fov=1 reduced_motion=1")
    quit(0)

func _fail(message: String) -> void:
    push_error("YARDMAN_VEHICLE_CAMERA_PRESENTATION_TEST FAIL: " + message)
    quit(1)
