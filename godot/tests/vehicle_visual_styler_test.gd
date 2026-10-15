extends SceneTree

const Styler = preload("res://scripts/vehicle_visual_styler.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_VISUAL_STYLER_TEST: " + message)

func _run() -> void:
    var root_node := Node3D.new()
    root.add_child(root_node)

    var body := MeshInstance3D.new()
    body.name = "CrownBodyPaint"
    var mesh := BoxMesh.new()
    mesh.size = Vector3(1.8, 1.3, 4.8)
    var source_material := StandardMaterial3D.new()
    source_material.resource_name = "CrownPaint"
    source_material.albedo_color = Color(0.72, 0.01, 0.01, 1.0)
    source_material.metallic = 0.60
    source_material.roughness = 0.20
    mesh.material = source_material
    body.mesh = mesh
    root_node.add_child(body)

    var profile := {
        "id": "toyota_crown",
        "paint_rgb": [0.72, 0.01, 0.01],
    }
    var stats: Dictionary = Styler.apply(root_node, profile)
    var styled := body.get_active_material(0) as StandardMaterial3D

    _check(styled != null, "Crown body has no styled material")
    if styled != null:
        _check(absf(styled.metallic - 0.0) < 0.0001, "Recovered Crown paint must remain dielectric")
        _check(absf(styled.roughness - 0.12) < 0.0001, "Recovered Crown smoothness mapping regressed")
        _check(styled.clearcoat_enabled, "Crown clearcoat disabled")
        _check(absf(styled.clearcoat_roughness - 0.10) < 0.0001, "Crown clearcoat response regressed")
        _check(styled != source_material, "Styler mutated the shared source material in place")
    _check(int(stats.get("paint_materials", 0)) == 1, "Crown paint surface was not classified exactly once")
    _check(str(stats.get("vehicle_id", "")) == "toyota_crown", "Crown visual identity metadata regressed")

    print("YARDMAN_VEHICLE_VISUAL_STYLER_TEST %s crown_dielectric=1 roughness=0.12 clearcoat=0.10" % ("PASS" if failures == 0 else "FAIL"))
    root_node.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
