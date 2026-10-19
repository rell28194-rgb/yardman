extends RefCounted
class_name YardmanRenderShadowPolicy

# Validated RDX-010 shadow distribution policy, separated from the retired
# RenderRuntime autoload so the clean map-and-cars architecture stays intact.
static func shadow_profile_for(quality: String, thermal_stage: int) -> Dictionary:
    var name := quality if quality in ["Performance", "Balanced", "Quality", "Ultra", "Custom"] else "Balanced"
    var stage := clampi(thermal_stage, 0, 5)
    if stage >= 5:
        return {
            "mode": DirectionalLight3D.SHADOW_ORTHOGONAL,
            "split_1": 0.30,
            "split_2": 0.55,
            "split_3": 0.78,
            "fade_start": 0.68,
            "blend_splits": false,
        }
    if stage >= 3 or name in ["Performance", "Balanced"]:
        return {
            "mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
            "split_1": 0.26 if name == "Performance" else 0.22,
            "split_2": 0.50,
            "split_3": 0.72,
            "fade_start": 0.72,
            "blend_splits": false,
        }
    var ultra := name == "Ultra"
    return {
        "mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
        "split_1": 0.07 if ultra else 0.08,
        "split_2": 0.18 if ultra else 0.20,
        "split_3": 0.42 if ultra else 0.46,
        "fade_start": 0.76,
        "blend_splits": false,
    }

static func apply_to_light(sun: DirectionalLight3D, active: Dictionary) -> void:
    if sun == null:
        return
    var profile := shadow_profile_for(
        str(active.get("quality", "Balanced")),
        int(active.get("thermal_stage", 0)))
    sun.directional_shadow_max_distance = maxf(10.0, float(active.get("shadow_distance", 82.0)))
    sun.directional_shadow_mode = int(profile.mode) as DirectionalLight3D.ShadowMode
    sun.directional_shadow_split_1 = float(profile.split_1)
    sun.directional_shadow_split_2 = float(profile.split_2)
    sun.directional_shadow_split_3 = float(profile.split_3)
    sun.directional_shadow_fade_start = float(profile.fade_start)
    sun.directional_shadow_blend_splits = bool(profile.blend_splits)
