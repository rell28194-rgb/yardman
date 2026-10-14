extends RefCounted
class_name YardmanRenderMaterialRegistry

# Renderer/tier-specific material families. Expensive and safe paths are kept
# as separate shader resources so Android GLES never compiles one giant shader
# full of dormant high-end branches.
const ROAD_HIGH: Shader = preload("res://shaders/road_surface.gdshader")
const ROAD_SAFE: Shader = preload("res://shaders/road_surface_gles.gdshader")
const WATER_HIGH: Shader = preload("res://shaders/water.gdshader")
const WATER_SAFE: Shader = preload("res://shaders/water_gles.gdshader")
const TERRAIN_HIGH: Shader = preload("res://shaders/terrain_surface.gdshader")
const TERRAIN_SAFE: Shader = preload("res://shaders/terrain_surface_gles.gdshader")

static func renderer_family(renderer_override: String = "") -> String:
    if not renderer_override.is_empty():
        return _normalize_renderer(renderer_override)
    var key := "rendering/renderer/rendering_method.mobile" if OS.has_feature("mobile") else "rendering/renderer/rendering_method"
    return _normalize_renderer(str(ProjectSettings.get_setting(key, "gl_compatibility")))

static func _normalize_renderer(value: String) -> String:
    if value in ["mobile", "vulkan_mobile"]:
        return "vulkan_mobile"
    if value in ["gl_compatibility", "gles", "opengl3"]:
        return "gles"
    return value

static func safe_variant(renderer_override: String = "", quality: String = "Balanced", force_safe: bool = false) -> bool:
    if force_safe:
        return true
    var renderer := renderer_family(renderer_override)
    return renderer == "gles" or quality == "Performance"

static func shader_for(surface: String, renderer_override: String = "", quality: String = "Balanced", force_safe: bool = false) -> Shader:
    var safe := safe_variant(renderer_override, quality, force_safe)
    match surface:
        "road":
            return ROAD_SAFE if safe else ROAD_HIGH
        "water":
            return WATER_SAFE if safe else WATER_HIGH
        "terrain":
            return TERRAIN_SAFE if safe else TERRAIN_HIGH
        _:
            push_error("RenderMaterialRegistry: unknown surface family %s" % surface)
            return ROAD_SAFE

static func variant_name(surface: String, renderer_override: String = "", quality: String = "Balanced", force_safe: bool = false) -> String:
    return "%s:%s" % [surface, "safe" if safe_variant(renderer_override, quality, force_safe) else "high"]

static func paths() -> Dictionary:
    return {
        "road_high": ROAD_HIGH.resource_path,
        "road_safe": ROAD_SAFE.resource_path,
        "water_high": WATER_HIGH.resource_path,
        "water_safe": WATER_SAFE.resource_path,
        "terrain_high": TERRAIN_HIGH.resource_path,
        "terrain_safe": TERRAIN_SAFE.resource_path,
    }
