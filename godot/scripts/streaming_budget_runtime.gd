extends Node
class_name YardmanStreamingBudgetRuntime

# Preserves full-island systems while reducing resident/detail work under
# sustained mobile pressure. Budgets are derived from the selected quality
# baseline each time, so thermal recovery is reversible rather than destructive.
const BASELINES := {
    "Performance": {"road_radius": 1, "terrain_radius": 1, "road_distance": 900.0, "road_prediction": 850.0, "building_distance": 450.0, "building_cells": 48},
    "Balanced": {"road_radius": 1, "terrain_radius": 1, "road_distance": 1200.0, "road_prediction": 1000.0, "building_distance": 650.0, "building_cells": 56},
    "Quality": {"road_radius": 2, "terrain_radius": 2, "road_distance": 2100.0, "road_prediction": 1200.0, "building_distance": 1100.0, "building_cells": 112},
    "Ultra": {"road_radius": 3, "terrain_radius": 2, "road_distance": 3000.0, "road_prediction": 1400.0, "building_distance": 1450.0, "building_cells": 160},
    "Custom": {"road_radius": 1, "terrain_radius": 1, "road_distance": 1200.0, "road_prediction": 1000.0, "building_distance": 650.0, "building_cells": 56},
}

var _last_signature := ""
var _last_budget: Dictionary = {}

func _ready() -> void:
    add_to_group("yardman_render_quality")

static func budget_for(quality: String, thermal_stage: int, custom: Dictionary = {}) -> Dictionary:
    var name := quality if BASELINES.has(quality) else "Balanced"
    var base: Dictionary = BASELINES[name].duplicate(true)
    if name == "Custom":
        base["road_radius"] = clampi(int(custom.get("road_radius", base.road_radius)), 1, 3)
        base["terrain_radius"] = clampi(int(custom.get("terrain_radius", base.terrain_radius)), 1, 2)
        base["road_distance"] = clampf(float(custom.get("road_distance", base.road_distance)), 700.0, 3400.0)
        base["road_prediction"] = clampf(float(custom.get("road_prediction", base.road_prediction)), 500.0, 1600.0)
        base["building_distance"] = clampf(float(custom.get("building_distance", base.building_distance)), 256.0, 1800.0)
        base["building_cells"] = clampi(int(custom.get("building_cells", base.building_cells)), 24, 192)

    var stage := clampi(thermal_stage, 0, 5)
    var distance_factor: float = float([1.0, 0.96, 0.92, 0.82, 0.68, 0.55][stage])
    var cell_factor: float = float([1.0, 1.0, 0.92, 0.78, 0.64, 0.50][stage])
    var geometry_factor: float = float([1.0, 0.95, 0.86, 0.74, 0.62, 0.52][stage])
    var road_radius := int(base.road_radius)
    var terrain_radius := int(base.terrain_radius)
    if stage >= 2:
        road_radius = mini(road_radius, 2)
    if stage >= 3:
        terrain_radius = 1
    if stage >= 5:
        road_radius = 1

    return {
        "road_radius": clampi(road_radius, 1, 3),
        "terrain_radius": clampi(terrain_radius, 1, 2),
        "road_distance": maxf(650.0, float(base.road_distance) * distance_factor),
        # Prediction is intentionally not reduced as aggressively as draw/residency
        # distance: under pressure we still prepare the direction of travel early.
        "road_prediction": maxf(500.0, float(base.road_prediction) * maxf(0.78, distance_factor)),
        "building_distance": maxf(320.0, float(base.building_distance) * distance_factor),
        "building_cells": maxi(24, int(round(float(base.building_cells) * cell_factor))),
        "road_geometry_us": maxi(700, int(round(1500.0 * geometry_factor))),
        "terrain_geometry_us": maxi(750, int(round(1600.0 * geometry_factor))),
        "building_geometry_us": maxi(550, int(round(1000.0 * geometry_factor))),
        "road_segments_per_frame": maxi(72, int(round(208.0 * geometry_factor))),
        "building_records_per_frame": maxi(5, int(round(12.0 * geometry_factor))),
        "io_jobs": 1 if name in ["Performance", "Balanced", "Custom"] or stage >= 2 else 2,
        "thermal_stage": stage,
        "quality": name,
    }

func apply_render_policy(active: Dictionary) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    var quality := str(active.get("quality", "Balanced"))
    var stage := clampi(int(active.get("thermal_stage", 0)), 0, 5)
    var custom: Dictionary = {}
    var visuals = scene.get("visuals")
    if visuals != null:
        var custom_value = visuals.get("custom")
        if custom_value is Dictionary:
            custom = custom_value
    var budget := budget_for(quality, stage, custom)
    var signature := JSON.stringify(budget)
    if signature == _last_signature:
        return

    var roads = scene.get("roads")
    var terrain = scene.get("terrain")
    var buildings = scene.get("buildings")
    var road_radius_changed := false
    var terrain_radius_changed := false
    var road_distance_changed := false

    if roads != null:
        road_radius_changed = int(roads.get("load_radius")) != int(budget.road_radius)
        road_distance_changed = not is_equal_approx(float(roads.get("stream_distance_m")), float(budget.road_distance)) or not is_equal_approx(float(roads.get("prediction_max_m")), float(budget.road_prediction))
        roads.set("load_radius", int(budget.road_radius))
        roads.set("stream_distance_m", float(budget.road_distance))
        roads.set("prediction_max_m", float(budget.road_prediction))
        roads.set("geometry_budget_us", int(budget.road_geometry_us))
        roads.set("max_segments_per_frame", int(budget.road_segments_per_frame))
        roads.set("max_io_jobs", int(budget.io_jobs))
    if terrain != null:
        terrain_radius_changed = int(terrain.get("load_radius")) != int(budget.terrain_radius)
        terrain.set("load_radius", int(budget.terrain_radius))
        terrain.set("geometry_budget_us", int(budget.terrain_geometry_us))
        terrain.set("max_segments_per_frame", int(budget.road_segments_per_frame))
        terrain.set("max_io_jobs", int(budget.io_jobs))
    if buildings != null:
        buildings.set("draw_distance", float(budget.building_distance))
        buildings.set("max_loaded_cells", int(budget.building_cells))
        buildings.set("geometry_budget_us", int(budget.building_geometry_us))
        buildings.set("max_buildings_per_frame", int(budget.building_records_per_frame))
        buildings.set("max_io_jobs", int(budget.io_jobs))

    if (road_radius_changed or road_distance_changed) and roads != null and roads.has_method("_refresh_tiles"):
        roads.call("_refresh_tiles", true)
    if terrain_radius_changed and terrain != null and terrain.has_method("_refresh_tiles"):
        terrain.call("_refresh_tiles", true)
    if buildings != null and buildings.has_method("update_world"):
        var target = buildings.get("target")
        var coordinates = buildings.get("coordinates")
        if target is Node3D and coordinates != null:
            var world: PackedFloat64Array = coordinates.local_to_world((target as Node3D).global_position)
            buildings.call("update_world", world[0], world[2], true)

    _last_signature = signature
    _last_budget = budget.duplicate(true)

func runtime_snapshot() -> Dictionary:
    return _last_budget.duplicate(true)
