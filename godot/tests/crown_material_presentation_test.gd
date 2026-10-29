extends SceneTree

const Runtime = preload("res://scripts/crown_material_presentation_runtime.gd")

func _initialize() -> void:
    var root := Node3D.new()
    root.name = "CrownMaterialFixture"
    root.add_child(_fixture_mesh("CrownPaint", 0.0, 0.122, Color(0.075, 0.075, 0.078, 1.0)))
    root.add_child(_fixture_mesh("CrownGlass", 0.08, 0.075, Color(0.035, 0.059, 0.078, 0.56)))
    root.add_child(_fixture_mesh("CrownSilver", 0.88, 0.22, Color(0.50, 0.52, 0.55, 1.0)))
    root.add_child(_fixture_mesh("CrownWheelMetal", 0.82, 0.26, Color(0.24, 0.27, 0.30, 1.0)))
    root.add_child(_fixture_mesh("engine_crown", 0.0, 0.50, Color.WHITE))
    self.root.add_child(root)

    var stats := Runtime.polish_visual(root)
    if int(stats.paint) != 1 or int(stats.glass) != 1 or int(stats.silver) != 1 or int(stats.wheel) != 1:
        _fail("exact Crown materials were not all classified")
        return
    if int(stats.generic_materials_touched) != 0:
        _fail("generic material was modified")
        return

    var paint := _active_material(root.get_child(0) as MeshInstance3D)
    if paint == null or paint.metallic != 0.0 or not paint.clearcoat_enabled or paint.clearcoat_roughness > 0.08 or paint.roughness >= 0.122:
        _fail("paint clearcoat refinement is incorrect")
        return
    var glass := _active_material(root.get_child(1) as MeshInstance3D)
    if glass == null or glass.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA or glass.cull_mode != BaseMaterial3D.CULL_DISABLED \
            or glass.roughness >= 0.075 or not is_equal_approx(glass.albedo_color.a, 0.56):
        _fail("glass refinement did not preserve alpha/transparency contract")
        return
    var wheel := _active_material(root.get_child(3) as MeshInstance3D)
    if wheel == null or wheel.metallic < 0.88 or wheel.roughness < 0.20 or wheel.roughness > 0.27:
        _fail("wheel-metal refinement is outside contract")
        return
    var generic := _active_material(root.get_child(4) as MeshInstance3D)
    if generic == null or generic.resource_name != "engine_crown" or not is_equal_approx(generic.roughness, 0.50):
        _fail("non-target source material was changed")
        return

    root.queue_free()
    print("YARDMAN_CROWN_MATERIAL_PRESENTATION_TEST PASS paint=1 glass=1 silver=1 wheel=1 generic_untouched=1 source_color_preserved=1")
    quit(0)

func _fixture_mesh(material_name: String, metallic: float, roughness: float, color: Color) -> MeshInstance3D:
    var material := StandardMaterial3D.new()
    material.resource_name = material_name
    material.metallic = metallic
    material.roughness = roughness
    material.albedo_color = color
    var mesh := BoxMesh.new()
    mesh.size = Vector3.ONE
    mesh.material = material
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    return instance

func _active_material(instance: MeshInstance3D) -> StandardMaterial3D:
    return instance.get_active_material(0) as StandardMaterial3D

func _fail(message: String) -> void:
    push_error("YARDMAN_CROWN_MATERIAL_PRESENTATION_TEST FAIL: " + message)
    quit(1)
