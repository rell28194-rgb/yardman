extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const ModelScript = preload("res://scripts/vehicle_model.gd")

var failures := 0
var checks := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("PRIVATE_OWNER_ASSET_TEST: " + message)

func _run() -> void:
    var packed := References.scene("toyota_crown_2013.glb")
    _check(packed != null, "Manifest-verified Crown007 scene did not load")
    if packed == null:
        print("YARDMAN_PRIVATE_OWNER_ASSET_TEST FAIL checks=%d" % checks)
        quit(1)
        return

    var model = ModelScript.new()
    root.add_child(model)
    model.call("build", "toyota_crown_2013.glb")
    _check(bool(model.get("is_reference_model")), "Crown007 was not accepted as a reference model")
    _check(str(model.get("reference_asset_name")) == "toyota_crown_2013.glb", "Crown007 reference identity was lost")
    _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), "Crown007 did not bind as a dedicated hero mesh")
    _check(str(model.get_meta("yardman_dedicated_vehicle_id", "")) == "toyota_crown", "Crown007 bound to the wrong vehicle id")
    _check(model.find_child("BodyShell", true, false) != null, "Crown007 BodyShell is missing")
    _check((model.get("wheels") as Array).size() == 4, "Crown007 does not expose four independent wheel spins")
    _check((model.get("front_pivots") as Array).size() == 2, "Crown007 does not expose two front steering pivots")
    var bounds: AABB = model.get("geometry_bounds")
    _check(bounds.size.x > 1.8 and bounds.size.x < 2.3, "Crown007 width is outside expected metre scale")
    _check(bounds.size.y > 1.1 and bounds.size.y < 1.6, "Crown007 height is outside expected metre scale")
    _check(bounds.size.z > 4.5 and bounds.size.z < 5.3, "Crown007 length is outside expected metre scale")
    _check(float(model.get("wheelbase_m")) > 2.6 and float(model.get("wheelbase_m")) < 3.1, "Crown007 wheelbase is outside expected metre scale")
    _check(float(model.get("wheel_radius_m")) > 0.28 and float(model.get("wheel_radius_m")) < 0.42, "Crown007 wheel radius is outside expected metre scale")
    _check(model.get("brake_material") != null, "Crown007 brake lamp material did not bind")
    _check(model.get("reverse_material") != null, "Crown007 reverse lamp material did not bind")

    print("YARDMAN_PRIVATE_OWNER_ASSET_TEST %s checks=%d asset=toyota_crown_2013.glb dedicated=1 wheels=4" % ["PASS" if failures == 0 else "FAIL", checks])
    model.free()
    quit(0 if failures == 0 else 1)
