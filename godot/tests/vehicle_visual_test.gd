extends SceneTree

const Styler = preload("res://scripts/vehicle_visual_styler.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const ModelScript = preload("res://scripts/vehicle_model.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_VISUAL_TEST: " + message)

func _make_sample() -> Node3D:
    var root_node := Node3D.new()
    var body := MeshInstance3D.new()
    body.name = "BodyPaint"
    var body_mesh := BoxMesh.new()
    var body_material := StandardMaterial3D.new()
    body_material.resource_name = "CarPaint"
    body_material.albedo_color = Color(0.14, 0.31, 0.37)
    body_material.metallic = 0.52
    body_material.roughness = 0.27
    body_mesh.material = body_material
    body.mesh = body_mesh
    root_node.add_child(body)

    var glass := MeshInstance3D.new()
    glass.name = "WindshieldGlass"
    var glass_mesh := BoxMesh.new()
    var glass_material := StandardMaterial3D.new()
    glass_material.resource_name = "Glass"
    glass_material.albedo_color = Color(0.055, 0.125, 0.16)
    glass_material.metallic = 0.40
    glass_material.roughness = 0.13
    glass_mesh.material = glass_material
    glass.mesh = glass_mesh
    root_node.add_child(glass)

    var wheel := MeshInstance3D.new()
    wheel.name = "AlloyWheel"
    var wheel_mesh := CylinderMesh.new()
    var wheel_material := StandardMaterial3D.new()
    wheel_material.resource_name = "AlloyRim"
    wheel_material.albedo_color = Color(0.54, 0.58, 0.62)
    wheel_material.metallic = 0.82
    wheel_material.roughness = 0.25
    wheel_mesh.material = wheel_material
    wheel.mesh = wheel_mesh
    root_node.add_child(wheel)
    return root_node

func _paint_color(root_node: Node3D) -> Color:
    var body := root_node.get_node("BodyPaint") as MeshInstance3D
    return (body.get_active_material(0) as StandardMaterial3D).albedo_color

func _wheel_world_span(model: Node3D) -> Vector2:
    var spins_value = model.get("wheels")
    if not spins_value is Array or spins_value.is_empty():
        return Vector2.ZERO
    var min_x := INF
    var max_x := -INF
    var min_z := INF
    var max_z := -INF
    for spin_value in spins_value:
        if not spin_value is Node3D:
            continue
        var pivot := (spin_value as Node3D).get_parent() as Node3D
        if pivot == null:
            continue
        min_x = minf(min_x, pivot.position.x * model.scale.x)
        max_x = maxf(max_x, pivot.position.x * model.scale.x)
        min_z = minf(min_z, pivot.position.z * model.scale.z)
        max_z = maxf(max_z, pivot.position.z * model.scale.z)
    if min_x == INF or min_z == INF:
        return Vector2.ZERO
    return Vector2(max_x - min_x, max_z - min_z)

func _run() -> void:
    var crown := _make_sample()
    root.add_child(crown)
    var crown_stats := Styler.apply(crown, Catalog.profile("toyota_crown"))
    var crown_color := _paint_color(crown)
    _check(int(crown_stats.paint_materials) == 1, "Crown paint material was not identified")
    _check(int(crown_stats.glass_materials) == 1, "Crown glass material was not identified")
    _check(int(crown_stats.wheel_materials) == 1, "Crown wheel material was not identified")
    _check((crown.get_node("BodyPaint") as MeshInstance3D).get_active_material(0).get("clearcoat_enabled") == true, "Hero paint clearcoat was not enabled")
    _check((crown.get_node("WindshieldGlass") as MeshInstance3D).get_active_material(0).get("transparency") == BaseMaterial3D.TRANSPARENCY_ALPHA, "Hero glass did not receive alpha transparency")

    var mark_x := _make_sample()
    root.add_child(mark_x)
    Styler.apply(mark_x, Catalog.profile("toyota_mark_x"))
    var mark_color := _paint_color(mark_x)
    var sports := _make_sample()
    root.add_child(sports)
    Styler.apply(sports, Catalog.profile("port_royal_992"))
    var sports_color := _paint_color(sports)
    _check(not crown_color.is_equal_approx(mark_color), "Crown and Mark X still have identical hero paint identity")
    _check(not mark_color.is_equal_approx(sports_color), "Mark X and Port Royal still have identical hero paint identity")
    _check(str(sports.get_meta("yardman_vehicle_visual_id", "")) == "port_royal_992", "Visual rig did not retain its profile identity")

    var runtime = root.get_node_or_null("VehicleVisualRuntime")
    _check(runtime != null and runtime.has_method("style_visual"), "VehicleVisualRuntime autoload is not integrated")
    if runtime != null:
        var geometry_signatures: Array[String] = []
        for vehicle_id in Catalog.production_ids():
            var direct := _make_sample()
            root.add_child(direct)
            var direct_stats: Dictionary = runtime.style_visual(direct, str(vehicle_id))
            _check(str(direct_stats.get("vehicle_id", "")) == str(vehicle_id), "Runtime styling bridge applied the wrong profile for %s" % vehicle_id)
            _check(bool(direct_stats.get("profile_geometry", false)), "%s did not receive profile-aware fallback geometry" % vehicle_id)
            _check(int(direct_stats.get("geometry_mesh_parts", 0)) >= 10, "%s fallback geometry is too sparse to establish a distinct silhouette" % vehicle_id)
            var signature := str(direct_stats.get("geometry_signature", ""))
            _check(not signature.is_empty(), "%s geometry signature was not published" % vehicle_id)
            _check(str(direct.get_meta("yardman_geometry_identity", "")) == str(vehicle_id), "%s geometry identity metadata is wrong" % vehicle_id)
            _check(direct.get_node_or_null("ProfileIdentityGeometry") != null, "%s did not create its profile identity geometry node" % vehicle_id)
            geometry_signatures.append(signature)
            direct.queue_free()
        _check(geometry_signatures.size() == 3, "Production geometry signature coverage is incomplete")
        if geometry_signatures.size() == 3:
            _check(geometry_signatures[0] != geometry_signatures[1], "Crown and Mark X still share one geometry signature")
            _check(geometry_signatures[1] != geometry_signatures[2], "Mark X and Port Royal still share one geometry signature")
            _check(geometry_signatures[0] != geometry_signatures[2], "Crown and Port Royal still share one geometry signature")

        # Exercise the actual fallback wheel rig, not only metadata. The profile
        # stance layer must survive the controller's legacy visual scale and land
        # on the requested real-world wheelbase/track for every production car.
        for vehicle_id in Catalog.production_ids():
            var profile := Catalog.profile(str(vehicle_id))
            var model := ModelScript.new()
            root.add_child(model)
            model.build()
            var visual_scale: Array = profile.get("visual_scale", [1.0, 1.0, 1.0])
            model.scale = Vector3(float(visual_scale[0]), float(visual_scale[1]), float(visual_scale[2]))
            var model_stats: Dictionary = runtime.style_visual(model, str(vehicle_id))
            _check(int(model_stats.get("stance_wheels", 0)) == 4, "%s did not reposition all four fallback wheels" % vehicle_id)
            var span := _wheel_world_span(model)
            _check(absf(span.x - float(profile.track_width_m)) <= 0.025, "%s fallback track does not match its profile: %.3f vs %.3f" % [vehicle_id, span.x, float(profile.track_width_m)])
            _check(absf(span.y - float(profile.wheelbase_m)) <= 0.025, "%s fallback wheelbase does not match its profile: %.3f vs %.3f" % [vehicle_id, span.y, float(profile.wheelbase_m)])
            model.queue_free()

        var legacy := _make_sample()
        root.add_child(legacy)
        var legacy_stats: Dictionary = runtime.style_visual(legacy, "legacy_sedan")
        _check(not bool(legacy_stats.get("profile_geometry", true)), "Legacy sedan was incorrectly converted into production profile geometry")
        _check(legacy.get_node_or_null("ProfileIdentityGeometry") == null, "Legacy sedan received a production body replacement")
        legacy.queue_free()

    crown.queue_free()
    mark_x.queue_free()
    sports.queue_free()
    await process_frame
    print("YARDMAN_VEHICLE_VISUAL_TEST %s paint=1 glass=1 wheel=1 profile_identity=3 distinct_geometry=3 stance=3 runtime_bridge=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
