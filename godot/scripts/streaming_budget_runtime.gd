extends Node
class_name YardmanStreamingBudgetRuntime

# Preserves full-island systems while reducing resident/detail work under
# sustained mobile pressure. Budgets are derived from the selected quality
# baseline each time, so thermal recovery is reversible rather than destructive.
const BASELINES := {
    "Performance": {"road_radius": 1, "terrain_radius": 1, "building_distance": 450.0, "building_cells": 64},
    "Balanced": {"road_radius": 2, "terrain_radius": 1, "building_distance": 800.0, "building_cells": 96},
    "Quality": {"road_radius": 2, "terrain_radius": 2, "building_distance": 1100.0, "building_cells": 144},
    "Ultra": {"road_radius": 3, "terrain_radius": 2, "building_distance": 1450.0, "building_cells": 192},
    "Custom": {"road_radius": 2, "terrain_radius": 1, "building_distance": 800.0, "building_cells": 96},
}
const ROADSIDE_BUCKET_M := 64.0
const ROADSIDE_CULL_CELL_M := 256.0
const ROADSIDE_MAX_PLANTS := 1800

var _last_signature := ""
var _last_budget: Dictionary = {}

# Road tiles used to synchronously fan out into vegetation construction on the
# same frame that their ArrayMesh surfaces were uploaded. This scheduler takes
# ownership of those two signals and spreads roadside preparation/instancing
# across later frames under the same thermal budget system as roads/terrain.
var _roadside_scene_id := 0
var _roadside_scene: Node
var _roadside_roads: Node
var _roadside_terrain: Node
var _roadside_visuals
var _roadside_pending: Dictionary = {}
var _roadside_jobs: Dictionary = {}
var _roadside_order: Array[Vector2i] = []

func _ready() -> void:
    add_to_group("yardman_render_quality")
    process_mode = Node.PROCESS_MODE_ALWAYS
    call_deferred("_install_current_scene")

func _process(_delta: float) -> void:
    _install_current_scene()
    _pump_roadside_jobs()

func _exit_tree() -> void:
    _detach_roadside_scheduler()

static func budget_for(quality: String, thermal_stage: int, custom: Dictionary = {}) -> Dictionary:
    var name := quality if BASELINES.has(quality) else "Balanced"
    var base: Dictionary = BASELINES[name].duplicate(true)
    if name == "Custom":
        base["road_radius"] = clampi(int(custom.get("road_radius", base.road_radius)), 1, 3)
        base["terrain_radius"] = clampi(int(custom.get("terrain_radius", base.terrain_radius)), 1, 2)
        base["building_distance"] = clampf(float(custom.get("building_distance", base.building_distance)), 256.0, 1800.0)
        base["building_cells"] = clampi(int(custom.get("building_cells", base.building_cells)), 32, 224)

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
        "building_distance": maxf(320.0, float(base.building_distance) * distance_factor),
        "building_cells": maxi(32, int(round(float(base.building_cells) * cell_factor))),
        "road_geometry_us": maxi(1100, int(round(2500.0 * geometry_factor))),
        "terrain_geometry_us": maxi(1100, int(round(2500.0 * geometry_factor))),
        "building_geometry_us": maxi(800, int(round(1800.0 * geometry_factor))),
        "roadside_geometry_us": maxi(700, int(round(1400.0 * geometry_factor))),
        "road_segments_per_frame": maxi(128, int(round(384.0 * geometry_factor))),
        "building_records_per_frame": maxi(8, int(round(20.0 * geometry_factor))),
        "roadside_records_per_frame": maxi(8, int(round(24.0 * geometry_factor))),
        "io_jobs": 2 if stage < 3 else 1,
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

    if roads != null:
        road_radius_changed = int(roads.get("load_radius")) != int(budget.road_radius)
        roads.set("load_radius", int(budget.road_radius))
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

    if road_radius_changed and roads != null and roads.has_method("_refresh_tiles"):
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
    var snapshot := _last_budget.duplicate(true)
    snapshot["roadside_pending_tiles"] = _roadside_pending.size()
    snapshot["roadside_build_jobs"] = _roadside_jobs.size()
    snapshot["roadside_scheduler_installed"] = _roadside_scene_id != 0
    return snapshot

func _install_current_scene() -> void:
    var tree := get_tree()
    if tree == null:
        return
    var scene := tree.current_scene
    if scene != null:
        _install_roadside_scheduler(scene)

func _install_roadside_scheduler(scene: Node) -> void:
    if scene == null:
        return
    var roads_value = scene.get("roads")
    var terrain_value = scene.get("terrain")
    var visuals_value = scene.get("visuals")
    if not roads_value is Node or not terrain_value is Node or visuals_value == null:
        return
    var scene_id := scene.get_instance_id()
    if scene_id == _roadside_scene_id and roads_value == _roadside_roads and terrain_value == _roadside_terrain:
        return
    _detach_roadside_scheduler()
    _roadside_scene_id = scene_id
    _roadside_scene = scene
    _roadside_roads = roads_value as Node
    _roadside_terrain = terrain_value as Node
    _roadside_visuals = visuals_value

    var immediate_road := Callable(scene, "_decorate_tile")
    if scene.has_method("_decorate_tile") and _roadside_roads.is_connected("tile_content_ready", immediate_road):
        _roadside_roads.disconnect("tile_content_ready", immediate_road)
    var immediate_terrain := Callable(scene, "_decorate_ready_terrain")
    if scene.has_method("_decorate_ready_terrain") and _roadside_terrain.is_connected("tile_ready", immediate_terrain):
        _roadside_terrain.disconnect("tile_ready", immediate_terrain)

    var road_callback := Callable(self, "_queue_roadside_tile")
    var terrain_callback := Callable(self, "_queue_roadside_terrain")
    var removed_callback := Callable(self, "_drop_roadside_tile")
    if not _roadside_roads.is_connected("tile_content_ready", road_callback):
        _roadside_roads.connect("tile_content_ready", road_callback)
    if not _roadside_terrain.is_connected("tile_ready", terrain_callback):
        _roadside_terrain.connect("tile_ready", terrain_callback)
    if not _roadside_roads.is_connected("tile_removed", removed_callback):
        _roadside_roads.connect("tile_removed", removed_callback)

func _detach_roadside_scheduler() -> void:
    if is_instance_valid(_roadside_roads):
        var road_callback := Callable(self, "_queue_roadside_tile")
        var removed_callback := Callable(self, "_drop_roadside_tile")
        if _roadside_roads.is_connected("tile_content_ready", road_callback):
            _roadside_roads.disconnect("tile_content_ready", road_callback)
        if _roadside_roads.is_connected("tile_removed", removed_callback):
            _roadside_roads.disconnect("tile_removed", removed_callback)
    if is_instance_valid(_roadside_terrain):
        var terrain_callback := Callable(self, "_queue_roadside_terrain")
        if _roadside_terrain.is_connected("tile_ready", terrain_callback):
            _roadside_terrain.disconnect("tile_ready", terrain_callback)
    for job in _roadside_jobs.values():
        _free_staging(job)
    _roadside_pending.clear()
    _roadside_jobs.clear()
    _roadside_order.clear()
    _roadside_scene_id = 0
    _roadside_scene = null
    _roadside_roads = null
    _roadside_terrain = null
    _roadside_visuals = null

func _queue_roadside_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    _roadside_pending[tile] = {"root": tile_root, "segments": segments}
    if is_instance_valid(_roadside_terrain) and bool(_roadside_terrain.call("is_tile_ready", tile)):
        _start_roadside_job(tile)

func _queue_roadside_terrain(tile: Vector2i) -> void:
    if _roadside_pending.has(tile):
        _start_roadside_job(tile)

func _drop_roadside_tile(tile: Vector2i) -> void:
    _roadside_pending.erase(tile)
    if _roadside_jobs.has(tile):
        _free_staging(_roadside_jobs[tile])
        _roadside_jobs.erase(tile)
    _roadside_order.erase(tile)

func _start_roadside_job(tile: Vector2i) -> void:
    if _roadside_jobs.has(tile) or not _roadside_pending.has(tile):
        return
    if not is_instance_valid(_roadside_roads) or not is_instance_valid(_roadside_terrain) or _roadside_visuals == null:
        return
    if not bool(_roadside_terrain.call("is_tile_ready", tile)):
        return
    var source: Dictionary = _roadside_pending[tile]
    var root = source.get("root")
    if not root is Node3D or not is_instance_valid(root):
        return
    var staging := Node3D.new()
    staging.name = "RoadsideProxy"
    var prepared = source.get("records", [])
    var has_prepared := prepared is Array and not prepared.is_empty()
    _roadside_jobs[tile] = {
        "tile": tile,
        "root": root,
        "segments": [] if has_prepared else source.get("segments", []),
        "tile_size": float(_roadside_roads.get("tile_size")),
        "staging": staging,
        "phase": 1 if has_prepared else 0,
        "source_index": 0,
        "records": prepared.duplicate(true) if has_prepared else [],
        "seen": {},
        "bucket_index": 0,
        "buckets": {},
        "plant_index": 0,
        "occupied": {},
        "groups": {},
        "group_keys": [],
        "group_index": 0,
        "count": 0,
    }
    _roadside_order.append(tile)

func _pump_roadside_jobs() -> void:
    if _roadside_jobs.is_empty() or _roadside_visuals == null:
        return
    var budget_us := int(_last_budget.get("roadside_geometry_us", 1400))
    var unit_limit := int(_last_budget.get("roadside_records_per_frame", 24))
    var started := Time.get_ticks_usec()
    var units := 0
    while not _roadside_order.is_empty() and units < unit_limit:
        if units > 0 and Time.get_ticks_usec() - started >= budget_us:
            break
        var tile: Vector2i = _roadside_order.pop_front()
        if not _roadside_jobs.has(tile):
            continue
        var job: Dictionary = _roadside_jobs[tile]
        var completed := _step_roadside_job(job)
        units += 1
        if completed:
            _roadside_jobs.erase(tile)
        else:
            _roadside_jobs[tile] = job
            _roadside_order.append(tile)

func _step_roadside_job(job: Dictionary) -> bool:
    var root = job.get("root")
    var tile: Vector2i = job.get("tile", Vector2i.ZERO)
    if not root is Node3D or not is_instance_valid(root):
        _free_staging(job)
        return true
    if not is_instance_valid(_roadside_terrain) or not bool(_roadside_terrain.call("is_tile_ready", tile)):
        _free_staging(job)
        return true

    match int(job.phase):
        0:
            var segments: Array = job.segments
            var source_index := int(job.source_index)
            if source_index >= segments.size():
                var records: Array = job.records
                records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seed) < int(b.seed))
                job.records = records
                job.segments = []
                if _roadside_pending.has(tile):
                    _roadside_pending[tile] = {"root": root, "records": records.duplicate(true)}
                job.phase = 1
                return false
            var item = segments[source_index]
            job.source_index = source_index + 1
            if item is Array and item.size() >= 11:
                var segment: Array = item
                var key := "%s:%s:%s:%s:%s:%s" % [str(segment[7]), str(segment[8]), str(segment[0]), str(segment[1]), str(segment[2]), str(segment[3])]
                var seen: Dictionary = job.seen
                if not seen.has(key):
                    seen[key] = true
                    job.seen = seen
                    var records: Array = job.records
                    records.append({"a": Vector2(float(segment[0]), float(segment[1])), "b": Vector2(float(segment[2]), float(segment[3])),
                        "width": float(segment[4]), "ha": float(segment[9]), "hb": float(segment[10]), "seed": key.hash() & 0x7fffffff})
                    job.records = records
            return false
        1:
            var records: Array = job.records
            var bucket_index := int(job.bucket_index)
            if bucket_index >= records.size():
                job.phase = 2
                return false
            var road: Dictionary = records[bucket_index]
            var padding := float(road.width) * 0.5 + 4.0
            var a: Vector2 = road.a
            var b: Vector2 = road.b
            var min_cell := Vector2i(int(floor((minf(a.x, b.x) - padding) / ROADSIDE_BUCKET_M)), int(floor((minf(a.y, b.y) - padding) / ROADSIDE_BUCKET_M)))
            var max_cell := Vector2i(int(floor((maxf(a.x, b.x) + padding) / ROADSIDE_BUCKET_M)), int(floor((maxf(a.y, b.y) + padding) / ROADSIDE_BUCKET_M)))
            var buckets: Dictionary = job.buckets
            for z in range(min_cell.y, max_cell.y + 1):
                for x in range(min_cell.x, max_cell.x + 1):
                    var bucket_key := Vector2i(x, z)
                    if not buckets.has(bucket_key):
                        buckets[bucket_key] = []
                    buckets[bucket_key].append(bucket_index)
            job.buckets = buckets
            job.bucket_index = bucket_index + 1
            return false
        2:
            var records: Array = job.records
            var plant_index := int(job.plant_index)
            if int(job.count) >= ROADSIDE_MAX_PLANTS or plant_index >= records.size():
                var group_keys: Array = job.groups.keys()
                group_keys.sort()
                job.group_keys = group_keys
                job.phase = 3
                return false
            var record: Dictionary = records[plant_index]
            job.plant_index = plant_index + 1
            _prepare_roadside_record(job, record)
            return false
        3:
            var keys: Array = job.group_keys
            var group_index := int(job.group_index)
            if group_index >= keys.size():
                job.phase = 4
                return false
            var group_key = keys[group_index]
            var staging := job.staging as Node3D
            _roadside_visuals.call("_make_plant_cell", staging, job.groups[group_key], _tile_origin(job))
            job.group_index = group_index + 1
            return false
        _:
            return _finish_roadside_job(job)

func _prepare_roadside_record(job: Dictionary, record: Dictionary) -> void:
    if int(job.count) >= ROADSIDE_MAX_PLANTS:
        return
    var seed_value: int = record.seed
    if seed_value % 3 != 0:
        return
    var delta: Vector2 = record.b - record.a
    var length_m := delta.length()
    if length_m < 0.5:
        return
    var direction := delta / length_m
    var perpendicular := Vector2(-direction.y, direction.x)
    var repetitions := clampi(int(ceil(length_m / 55.0)), 1, 8)
    var tile: Vector2i = job.tile
    var tile_size := float(job.tile_size)
    var records: Array = job.records
    var buckets: Dictionary = job.buckets
    var occupied: Dictionary = job.occupied
    var groups: Dictionary = job.groups
    var count := int(job.count)
    var tile_origin := _tile_origin(job)

    for repetition in range(repetitions):
        for side in [-1.0, 1.0]:
            var seed_point := posmod(seed_value + repetition * 7927 + (9137 if side > 0.0 else 0), 2147483647)
            var fraction := (float(repetition) + 0.20 + float(seed_point % 601) / 1000.0) / float(repetitions)
            var distance := float(record.width) * 0.5 + 7.0 + float(seed_point % 2100) / 100.0
            var point: Vector2 = record.a + delta * fraction + perpendicular * distance * side
            if not _inside_tile(point, tile, tile_size) or _inside_road(point, buckets, records, 2.5):
                continue
            var occupancy := Vector2i(int(floor(point.x / 7.0)), int(floor(point.y / 7.0)))
            if occupied.has(occupancy):
                continue
            var height := float(_roadside_terrain.call("height_at", point.x, point.y))
            if is_nan(height) or is_inf(height) or height < 1.35:
                continue
            var species := "palm" if height < 220.0 and seed_point % 5 != 0 else "broadleaf"
            if seed_point % 7 == 0:
                species = "shrub"
            var scale_value := 0.72 + float(seed_point % 650) / 1000.0
            if species == "shrub":
                scale_value *= 0.36
            var basis := Basis(Vector3.UP, float(seed_point % 6283) / 1000.0).scaled(Vector3.ONE * scale_value)
            var position_local := Vector3(point.x - tile_origin.x, height, point.y - tile_origin.y)
            var cell := Vector2i(int(floor(position_local.x / ROADSIDE_CULL_CELL_M)), int(floor(position_local.z / ROADSIDE_CULL_CELL_M)))
            var key := "%d:%d:%s" % [cell.x, cell.y, species]
            if not groups.has(key):
                groups[key] = {"species": species, "cell": cell, "plants": []}
            groups[key].plants.append({"transform": Transform3D(basis, position_local), "seed": seed_point})
            occupied[occupancy] = true
            count += 1
            if count >= ROADSIDE_MAX_PLANTS:
                break
        if count >= ROADSIDE_MAX_PLANTS:
            break

    job.occupied = occupied
    job.groups = groups
    job.count = count

func _finish_roadside_job(job: Dictionary) -> bool:
    var root = job.get("root")
    var staging = job.get("staging")
    if not root is Node3D or not is_instance_valid(root) or not staging is Node3D or not is_instance_valid(staging):
        _free_staging(job)
        return true
    var existing := (root as Node3D).get_node_or_null("RoadsideProxy")
    if existing != null:
        (root as Node3D).remove_child(existing)
        existing.queue_free()
    var roadside := staging as Node3D
    roadside.name = "RoadsideProxy"
    roadside.set_meta("plant_count", int(job.count))
    roadside.set_meta("yardman_budgeted_stream_build", true)
    (root as Node3D).add_child(roadside)
    _roadside_visuals.call("apply_roadside_quality", root)
    return true

func _free_staging(job: Dictionary) -> void:
    var staging = job.get("staging")
    if staging is Node and is_instance_valid(staging):
        var node := staging as Node
        if node.get_parent() != null:
            node.get_parent().remove_child(node)
            node.queue_free()
        else:
            node.free()

func _tile_origin(job: Dictionary) -> Vector2:
    var tile: Vector2i = job.tile
    var size := float(job.tile_size)
    return Vector2(float(tile.x) * size, float(tile.y) * size)

static func _inside_road(point: Vector2, buckets: Dictionary, records: Array, margin: float) -> bool:
    var cell := Vector2i(int(floor(point.x / ROADSIDE_BUCKET_M)), int(floor(point.y / ROADSIDE_BUCKET_M)))
    for index in buckets.get(cell, []):
        var road: Dictionary = records[int(index)]
        var a: Vector2 = road.a
        var delta: Vector2 = road.b - a
        var t := clampf((point - a).dot(delta) / maxf(delta.length_squared(), 0.000001), 0.0, 1.0)
        if point.distance_squared_to(a + delta * t) < pow(float(road.width) * 0.5 + margin, 2.0):
            return true
    return false

static func _inside_tile(point: Vector2, tile: Vector2i, tile_size: float) -> bool:
    return int(floor(point.x / tile_size)) == tile.x and int(floor(point.y / tile_size)) == tile.y
