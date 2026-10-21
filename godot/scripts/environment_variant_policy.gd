extends RefCounted
class_name YardmanEnvironmentVariantPolicy

# Variant selection is intentionally cell-level, not instance-level. A MultiMesh
# keeps one mesh for every instance in a cell, which preserves batching on Android.
# The key must come from stable streamed-world identity (node/cell name), never a
# floating-origin local position.

static func choose(role: String, variants: Array, stable_key: String, elevation_m: float = 0.0) -> int:
    if variants.is_empty():
        return -1
    if variants.size() == 1:
        return 0
    var names: Array[String] = []
    for raw in variants:
        if raw is Dictionary:
            names.append(str((raw as Dictionary).get("variant", "")))
        else:
            names.append("")
    var seed := absi(stable_key.hash())
    if role == "tree_near":
        var broadleaf := names.find("broadleaf")
        if elevation_m >= 420.0 and broadleaf >= 0:
            return broadleaf
        var coastal: Array[int] = []
        for i in range(names.size()):
            if names[i].begins_with("coastal_"):
                coastal.append(i)
        if not coastal.is_empty():
            return coastal[seed % coastal.size()]
    elif role == "shrub_near":
        var fern := names.find("fern_wet")
        if elevation_m >= 260.0 and fern >= 0:
            return fern
        var dry_mix: Array[int] = []
        for i in range(names.size()):
            if names[i] != "fern_wet":
                dry_mix.append(i)
        if not dry_mix.is_empty():
            return dry_mix[seed % dry_mix.size()]
    return seed % variants.size()
