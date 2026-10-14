extends Node
class_name YardmanVegetationBudgetRuntime

var _last_factor := 1.0
var _last_visible_instances := 0
var _last_cells := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func apply_render_policy(active: Dictionary) -> void:
    var factor := clampf(float(active.get("vegetation_factor", 1.0)), 0.25, 1.0)
    var scene := get_tree().current_scene
    if scene == null:
        return
    var roads = scene.get("roads")
    var visuals = scene.get("visuals")
    if roads == null:
        return
    var loaded = roads.get("_loaded")
    if not loaded is Dictionary:
        return

    _last_visible_instances = 0
    _last_cells = 0
    for tile_root in loaded.values():
        if not tile_root is Node3D:
            continue
        # Rebuild the owner's selected quality baseline before applying thermal
        # pressure. This prevents repeated 0.74 -> 0.55 -> 0.41 compounding.
        if visuals != null and visuals.has_method("apply_roadside_quality"):
            visuals.call("apply_roadside_quality", tile_root)
        var roadside := (tile_root as Node3D).get_node_or_null("RoadsideProxy") as Node3D
        if roadside == null:
            continue
        var stats := apply_factor(roadside, factor)
        _last_visible_instances += int(stats.visible_instances)
        _last_cells += int(stats.cells)
    _last_factor = factor

static func apply_factor(roadside: Node3D, factor: float) -> Dictionary:
    if roadside == null:
        return {"cells": 0, "visible_instances": 0}
    var clamped := clampf(factor, 0.25, 1.0)
    var cells := 0
    var visible_instances := 0
    for child in roadside.get_children():
        if not child is MultiMeshInstance3D:
            continue
        var instance := child as MultiMeshInstance3D
        if instance.multimesh == null:
            continue
        var baseline_visible := instance.multimesh.visible_instance_count
        if baseline_visible < 0:
            baseline_visible = instance.multimesh.instance_count
        if not instance.has_meta("yardman_thermal_base_visible") or clamped >= 0.999:
            instance.set_meta("yardman_thermal_base_visible", baseline_visible)
        var base_visible := clampi(int(instance.get_meta("yardman_thermal_base_visible", baseline_visible)), 0, instance.multimesh.instance_count)
        var target := 0 if base_visible == 0 else maxi(1, int(ceil(float(base_visible) * clamped)))
        instance.multimesh.visible_instance_count = target

        if not instance.has_meta("yardman_thermal_base_range"):
            instance.set_meta("yardman_thermal_base_range", instance.visibility_range_end)
        var base_range := float(instance.get_meta("yardman_thermal_base_range", instance.visibility_range_end))
        # Instance count is the first lever. Draw distance contracts more gently
        # so thermal adaptation does not visibly erase the island around the car.
        instance.visibility_range_end = base_range * lerpf(0.72, 1.0, clamped)
        visible_instances += target
        cells += 1
    return {"cells": cells, "visible_instances": visible_instances}

func runtime_snapshot() -> Dictionary:
    return {"factor": _last_factor, "cells": _last_cells, "visible_instances": _last_visible_instances}
