extends SceneTree

const FleetRegistry = preload("res://scripts/vehicle_fleet_registry.gd")

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_VEHICLE_FLEET_CALIBRATION_TEST FAIL: " + message)
    quit(1)

func _initialize() -> void:
    var dmc := FleetRegistry.entry("delorean_dmc12")
    _require(not dmc.is_empty(), "DMC-12 selector missing")
    _require(str(dmc.get("source_identity", "")) == "DeloreanDMC12", "source identity changed")
    _require(str(dmc.get("source_sha256", "")) == "0f0d2e1f12bf5cd8c9da48c6ebd3480fca7573adb1089371a6f943bf5b2be763", "Beta1/source SHA changed")
    _require(str(dmc.get("hero_scene", "")) == "delorean_dmc12.glb", "dedicated hero changed")
    _require(str(dmc.get("runtime_variant", "")) == "canonical_5_speed_manual", "runtime variant not explicit")
    _require(str(dmc.get("transmission", "")) == "5-speed manual", "legacy transmission leaked into DMC-12")
    _require(absf(float(dmc.get("mass_kg", 0.0)) - 1225.0) < 0.01, "evidence-backed mass missing")
    _require(absf(float(dmc.get("peak_torque_nm", 0.0)) - 208.0) < 0.01, "evidence-backed torque missing")
    _require(absf(float(dmc.get("final_drive", 0.0)) - 3.44) < 0.0001, "final drive mismatch")
    _require(absf(float(dmc.get("reverse_ratio", 0.0)) - 3.1818) < 0.0001, "reverse ratio mismatch")
    var ratios: Array = dmc.get("gear_ratios", [])
    _require(ratios.size() == 5, "DMC-12 must not inherit six/eight-speed gearing")
    _require(absf(float(ratios[0]) - 3.364) < 0.0001 and absf(float(ratios[4]) - 0.8205) < 0.0001, "manual gear ratios mismatch")
    var front_radius := (14.0 * 25.4 + 2.0 * 195.0 * 0.60) / 2000.0
    var rear_radius := (15.0 * 25.4 + 2.0 * 235.0 * 0.60) / 2000.0
    _require(absf(float(dmc.get("front_tyre_radius_m", 0.0)) - front_radius) < 0.00001, "front tyre radius not derived from factory size")
    _require(absf(float(dmc.get("rear_tyre_radius_m", 0.0)) - rear_radius) < 0.00001, "rear tyre radius not derived from factory size")
    _require(absf(float(dmc.get("wheel_radius_m", 0.0)) - rear_radius) < 0.00001, "RWD powertrain radius must use documented rear tyre")
    _require(str(dmc.get("runtime_calibration_status", "")) == "mechanical_evidence_pass_visual_wheel_art_still_held", "visual acceptance boundary lost")

    var c7 := FleetRegistry.entry("corvette_c7")
    _require(not c7.is_empty(), "C7 selector missing")
    _require(str(c7.get("source_sha256", "")) == "a73a025b211c05e74514899f98511195742121168cb187473c41bbc7ae1b0c67", "C7 exact source identity regressed")
    _require(not c7.has("runtime_calibration_status"), "C7 received unproven trim calibration")

    print("YARDMAN_VEHICLE_FLEET_CALIBRATION_TEST PASS")
    quit(0)
