extends SceneTree

const StreetFurniture = preload("res://scripts/beta1_street_furniture_runtime.gd")
const WorkZones = preload("res://scripts/beta1_work_zone_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_STREET_FURNITURE_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var edge := {
        "mid": Vector3(0.0, 0.0, 0.0),
        "normal": Vector3.BACK,
        "length_m": 8.0,
    }
    var edge_copy := edge.duplicate(true)
    var road := {
        "point": Vector2(0.0, 10.0),
        "width_m": 6.0,
        "flags": 0,
    }

    var hydrant := StreetFurniture.plan_prop(edge, road, Vector2.ZERO, 14, 12)
    if str(hydrant.get("kind", "")) != "hydrant":
        _fail("dense paved frontage did not deterministically select hydrant")
        return
    var hydrant_point: Vector2 = hydrant.get("canonical", Vector2(INF, INF))
    if not hydrant_point.is_finite() or hydrant_point.y >= 7.0 or hydrant_point.y <= 3.0:
        _fail("hydrant was not placed outside pavement on the building side")
        return

    var bin := StreetFurniture.plan_prop(edge, road, Vector2.ZERO, 9, 5)
    if str(bin.get("kind", "")) != "bin":
        _fail("ordinary frontage did not deterministically select waste bin")
        return
    var cabinet := StreetFurniture.plan_prop(edge, road, Vector2.ZERO, 10, 5)
    if str(cabinet.get("kind", "")) != "cabinet":
        _fail("ordinary frontage did not deterministically select cabinet")
        return

    var rear := edge.duplicate(true)
    rear["normal"] = Vector3.FORWARD
    if not StreetFurniture.plan_prop(rear, road, Vector2.ZERO, 14, 12).is_empty():
        _fail("rear wall received street furniture")
        return
    var bridge_road := road.duplicate(true)
    bridge_road["flags"] = 2
    if not StreetFurniture.plan_prop(edge, bridge_road, Vector2.ZERO, 14, 12).is_empty():
        _fail("bridge frontage received settlement furniture")
        return
    var tunnel_road := road.duplicate(true)
    tunnel_road["flags"] = 4
    if not StreetFurniture.plan_prop(edge, tunnel_road, Vector2.ZERO, 14, 12).is_empty():
        _fail("tunnel frontage received settlement furniture")
        return
    if edge != edge_copy:
        _fail("planner mutated source frontage")
        return

    var contract := StreetFurniture.asset_contract()
    var files: Dictionary = contract.get("files", {})
    if str(files.get("bin", "")) != "settlement_waste_bin.glb" \
            or str(files.get("bin_blue", "")) != "settlement_waste_container_blue.glb" \
            or str(files.get("bin_yellow", "")) != "settlement_waste_container_yellow.glb" \
            or str(files.get("hydrant", "")) != "settlement_fire_hydrant.glb" \
            or str(files.get("cabinet", "")) != "settlement_metal_cabinet.glb":
        _fail("recovered Beta1 neutral prop filenames drifted")
        return
    if int(contract.get("max_props_per_cell", 999)) > 16 or float(contract.get("visibility_m", 999.0)) > 120.0:
        _fail("street furniture exceeded bounded near-field budget")
        return
    if bool(contract.get("collision", true)) or bool(contract.get("construction_props", true)):
        _fail("street furniture gained collision or construction-prop authority")
        return
    if not bool(contract.get("source_scale_preserved", false)):
        _fail("source metre-scale preservation contract missing")
        return
    if bool(contract.get("bin_variant_anchor_mutation", true)) \
            or bool(contract.get("bin_variant_density_mutation", true)) \
            or int(contract.get("max_extra_bin_batches", 99)) > 2 \
            or str(contract.get("asset_absent_fallback", "")) != "bin":
        _fail("waste-container variants exceeded one-for-one anchor/batch/fallback contract")
        return

    var variant_counts := {"bin": 0, "bin_blue": 0, "bin_yellow": 0}
    var all_variants := {"bin": true, "bin_blue": true, "bin_yellow": true}
    for seed in range(50):
        var kind := StreetFurniture.select_bin_kind(seed, all_variants)
        if not variant_counts.has(kind):
            _fail("waste-container selector emitted an unknown family")
            return
        variant_counts[kind] += 1
    if int(variant_counts.bin) <= int(variant_counts.bin_blue) \
            or int(variant_counts.bin) <= int(variant_counts.bin_yellow) \
            or int(variant_counts.bin_blue) <= 0 or int(variant_counts.bin_yellow) <= 0:
        _fail("waste-container selector lost bounded standard/blue/yellow mix")
        return
    for seed in range(20):
        if StreetFurniture.select_bin_kind(seed, {"bin": true}) != "bin":
            _fail("asset-absent private variants did not fall back to existing bin")
            return
    if StreetFurniture.select_bin_kind(0, {}) != "":
        _fail("selector invented a bin when no mesh family was available")
        return

    # Construction props are intentionally separate from ordinary settlement
    # furniture. They activate only against the non-drivable OSM construction
    # sidecar and retain the existing street-furniture gate marker below.
    var work_record := {
        "a": [0.0, 0.0, 0.0],
        "b": [32.0, 0.0, 0.0],
        "width_m": 6.4,
        "access": "no",
        "construction_class": "primary",
    }
    var work_copy := work_record.duplicate(true)
    var work_plan := WorkZones.placement_plan(work_record)
    var work_cones := 0
    var work_barriers := 0
    for item: Dictionary in work_plan:
        if str(item.get("kind", "")) == "cone":
            work_cones += 1
        elif str(item.get("kind", "")) == "barrier":
            work_barriers += 1
    if work_cones < 2 or work_cones > WorkZones.MAX_CONES_PER_SEGMENT or work_barriers != 2:
        _fail("mapped closed work zone did not produce bounded cones plus endpoint barriers")
        return
    var work_contract := WorkZones.asset_contract()
    var work_files: Dictionary = work_contract.get("files", {})
    if str(work_files.get("cone", "")) != "road_repair_cone.glb" \
            or str(work_files.get("barrier", "")) != "road_concrete_barrier.glb" \
            or str(work_files.get("fence", "")) != "road_portable_fence.glb":
        _fail("recovered Beta1 construction prop filenames drifted")
        return
    if str(work_contract.get("source_tag", "")) != "highway=construction" \
            or bool(work_contract.get("drivable", true)) \
            or bool(work_contract.get("navigation", true)) \
            or bool(work_contract.get("collision", true)) \
            or bool(work_contract.get("terrain_mutation", true)):
        _fail("work-zone props lost source/non-drivable isolation contract")
        return
    if work_record != work_copy:
        _fail("work-zone planner mutated source construction record")
        return

    print("YARDMAN_BETA1_STREET_FURNITURE_RUNTIME_TEST PASS hydrant=1 bin=1 cabinet=1 rear_rejected=1 bridge_rejected=1 tunnel_rejected=1 source_unchanged=1 near_only=1 collision=0 construction=0")
    quit(0)
