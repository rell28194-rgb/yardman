extends SceneTree

const Registry = preload("res://scripts/render_material_registry.gd")
const Coastline = preload("res://scripts/coastline.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("MATERIAL_VARIANTS_TEST: " + message)

func _run() -> void:
    for family in ["road", "water", "terrain"]:
        var high: Shader = Registry.shader_for(family, "vulkan_mobile", "Quality")
        var safe: Shader = Registry.shader_for(family, "gles", "Quality")
        _check(high != null and safe != null, "%s family did not load both variants" % family)
        _check(high.resource_path != safe.resource_path, "%s high/safe variants still resolve to one shader" % family)
        _check(Registry.variant_name(family, "vulkan_mobile", "Quality") == "%s:high" % family, "%s Vulkan path did not select high shader" % family)
        _check(Registry.variant_name(family, "gles", "Quality") == "%s:safe" % family, "%s GLES path did not select safe shader" % family)
        _check(Registry.variant_name(family, "vulkan_mobile", "Performance") == "%s:safe" % family, "%s Performance tier did not select safe shader" % family)

    var coastline = Coastline.new()
    root.add_child(coastline)
    coastline.apply_render_policy({"quality": "Quality", "water_variant": "depth"}, "vulkan_mobile")
    _check(coastline.water_material.shader.resource_path == "res://shaders/water.gdshader", "Vulkan coastline did not select high water shader")
    coastline.apply_render_policy({"quality": "Quality", "water_variant": "opaque"}, "vulkan_mobile")
    _check(coastline.water_material.shader.resource_path == "res://shaders/water_gles.gdshader", "Thermal/opaque policy did not switch coastline to safe water")
    coastline.apply_render_policy({"quality": "Quality", "water_variant": "depth"}, "gles")
    _check(coastline.water_material.shader.resource_path == "res://shaders/water_gles.gdshader", "GLES coastline escaped safe water path")
    coastline.queue_free()
    await process_frame
    print("YARDMAN_MATERIAL_VARIANTS_TEST %s families=3 runtime_water_switch=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
