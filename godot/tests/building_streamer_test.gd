extends SceneTree

const CoordinatesScript = preload("res://scripts/world_coordinates.gd")
const BuildingScript = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_STREAMER_TEST: " + message)

func _record(identifier: String) -> Array:
    return [identifier, 4.4, 3, 0, 9.4,
        [[[0, 5, 0], [20, 5, 0], [20, 5, 20], [0, 5, 20]]],
        [[0, 0], [20, 0], [20, 20], [0, 20]], [0, 2, 1, 0, 3, 2]]

func _source_record(identifier: String, shape: String = "gabled") -> Array:
    var record := _record(identifier)
    record[2] = 1
    record.append({"roof_shape": shape, "roof_height_m": 1.2, "roof_orientation": "along"})
    return record

func _geometry_build_state() -> Dictionary:
    return {"wall_vertices": PackedVector3Array(), "wall_normals": PackedVector3Array(),
        "wall_uvs": PackedVector2Array(), "wall_colors": PackedColorArray(),
        "wall_uv2s": PackedVector2Array(), "wall_indices": PackedInt32Array(), "facades": [],
        "roof_vertices": PackedVector3Array(), "roof_normals": PackedVector3Array(),
        "roof_uvs": PackedVector2Array(), "roof_colors": PackedColorArray(),
        "roof_indices": PackedInt32Array()}

func _check_visible_winding(mesh: ArrayMesh, label: String) -> void:
    var arrays := mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    for triangle in range(0, indices.size(), 3):
        var a: int = indices[triangle]
        var b: int = indices[triangle + 1]
        var c: int = indices[triangle + 2]
        var cross := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
        if cross.length_squared() > 0.000000001:
            _check(cross.dot(normals[a]) < 0.0, label + " contains a back-facing clockwise/normal mismatch")

func _write_pack(path: String, identifier: String) -> void:
    var bytes := JSON.stringify([_record(identifier)]).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_buffer("YMB1".to_ascii_buffer())
    file.store_32(1)
    file.store_16(0)
    file.store_16(0)
    file.store_32(20)
    file.store_32(bytes.size())
    file.store_buffer(bytes)
    file.close()

func _wait_idle(streamer) -> void:
    for frame in range(600):
        await process_frame
        if streamer.is_idle():
            return
    _check(false, "Streamer did not finish bounded synthetic cell jobs")

func _run() -> void:
    var root_path := "user://yardman/tests/buildings"
    DirAccess.make_dir_recursive_absolute(root_path)
    _write_pack(root_path + "/zero.ymb", "w42:0")
    _write_pack(root_path + "/far.ymb", "w99:0")
    var manifest := {"format": 1, "crs": "EPSG:3448", "origin": {"easting": 100000.0, "northing": 200000.0}, "tile_size": 4096, "cell_size": 256,
        "stats": {"buildings": 2, "cells": 2}, "tiles": [
            {"x": 0, "z": 0, "file": "zero.ymb", "cells": [[0, 0]]},
            {"x": 10, "z": 0, "file": "far.ymb", "cells": [[0, 0]]}]}
    var file := FileAccess.open(root_path + "/manifest.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(manifest))
    file.close()
    var coordinates = CoordinatesScript.new()
    coordinates.configure(manifest)
    var streamer = BuildingScript.new()
    streamer.configure(root_path, coordinates)
    var wall_source := StandardMaterial3D.new()
    wall_source.albedo_color = Color(0.41, 0.52, 0.38)
    var roof_source := StandardMaterial3D.new()
    roof_source.albedo_color = Color(0.54, 0.36, 0.25)
    streamer.set_surface_materials(wall_source, roof_source)
    root.add_child(streamer)
    streamer.update_world(10.0, 10.0, true)
    await _wait_idle(streamer)
    _check(streamer._loaded.size() == 1 and streamer._loaded.has("0:0"), "Near real cell did not load")
    _check(streamer.inflight_count() == 0, "In-flight count remained nonzero after cells completed")
    if streamer._loaded.has("0:0"):
        var entry: Dictionary = streamer._loaded["0:0"]
        _check(entry.count == 1 and entry.root.get_node("Walls").mesh.get_surface_count() == 1 and entry.root.get_node("Roofs").mesh.get_surface_count() == 1, "Cell did not produce merged wall and roof meshes")
        var walls := entry.root.get_node("Walls") as MeshInstance3D
        var roofs := entry.root.get_node("Roofs") as MeshInstance3D
        _check_visible_winding(walls.mesh, "Walls")
        _check_visible_winding(roofs.mesh, "Roofs")
        var roof_arrays := roofs.mesh.surface_get_arrays(0)
        var minimum_roof := INF
        var maximum_roof := -INF
        for point: Vector3 in roof_arrays[Mesh.ARRAY_VERTEX]:
            minimum_roof = minf(minimum_roof, point.y)
            maximum_roof = maxf(maximum_roof, point.y)
        _check(maximum_roof - minimum_roof > 0.5 and is_equal_approx(maximum_roof, 9.4), "Inferred hip roof lost source maximum height or remained a flat box")
        var measured := _record("measured")
        measured[2] = 1
        _check(streamer._inferred_hip_roof(measured).is_empty(), "Measured height was assigned an invented hip roof")
        var levels := measured.duplicate(true)
        levels[2] = 2
        _check(streamer._inferred_hip_roof(levels).is_empty(), "Source storeys were assigned an invented hip roof")
        var courtyard := _record("courtyard")
        courtyard[5].append([[8, 5, 8], [8, 5, 12], [12, 5, 12], [12, 5, 8]])
        _check(streamer._inferred_hip_roof(courtyard).is_empty(), "A courtyard was covered by an invented roof")
        var irregular := _record("irregular")
        irregular[5][0][2][0] = 14
        _check(streamer._inferred_hip_roof(irregular).is_empty(), "An irregular footprint was replaced with a rectangle")
        var source_gable := _source_record("source-gable")
        var source_roof: Dictionary = streamer._source_roof(source_gable)
        _check(not source_roof.is_empty() and source_roof.shape == "gabled", "Source gabled roof metadata did not produce roof massing")
        _check(is_equal_approx(float(source_roof.roof_y), 9.4) and is_equal_approx(float(source_roof.eaves_y), 8.2), "Source roof height changed the registered maximum building height")
        var source_hip := _source_record("source-hip", "hipped")
        _check(streamer._source_roof(source_hip).get("shape", "") == "hipped", "Source hipped roof metadata was ignored")
        var source_pyramid := _source_record("source-pyramid", "pyramidal")
        var pyramid: Dictionary = streamer._source_roof(source_pyramid)
        _check(not pyramid.is_empty() and (pyramid.ridge_a as Vector2).is_equal_approx(pyramid.ridge_b as Vector2), "Source pyramidal roof did not converge to an apex")
        var source_irregular := _source_record("source-irregular")
        source_irregular[5][0][2][0] = 14
        _check(streamer._source_roof(source_irregular).is_empty(), "Irregular source footprint was forced into a rectangular roof")

        var elevated := _source_record("elevated-part")
        elevated[1] = 12.0
        elevated[4] = 17.0
        elevated[8]["building_part"] = true
        elevated[8]["min_height_m"] = 4.0
        _check(is_equal_approx(streamer._source_base_offset(elevated), 4.0), "Source min_height did not become the part base offset")
        _check(streamer._inferred_hip_roof(elevated).is_empty(), "Building part received an invented fallback hip roof")
        var elevated_builder = BuildingScript.new()
        elevated_builder._build = _geometry_build_state()
        _check(elevated_builder._append_building(elevated), "Elevated building part could not build geometry")
        var minimum_wall := INF
        for point: Vector3 in elevated_builder._build.wall_vertices:
            minimum_wall = minf(minimum_wall, point.y)
        _check(is_equal_approx(minimum_wall, 9.0), "Elevated part wall did not start min_height above its 5m terrain foundation")
        var level_part := _source_record("level-part")
        level_part[8]["building_part"] = true
        level_part[8]["min_level"] = 2.0
        _check(is_equal_approx(elevated_builder._source_base_offset(level_part), 6.3), "building:min_level did not convert to the declared 3.15m storey pitch")
        elevated_builder.free()

        var wall_material := walls.mesh.surface_get_material(0) as StandardMaterial3D
        var roof_material := roofs.mesh.surface_get_material(0) as StandardMaterial3D
        _check(wall_material != null and wall_material != wall_source and wall_material.albedo_color == wall_source.albedo_color, "Imported wall material was not copied into the merged mesh")
        _check(roof_material != null and roof_material != roof_source and roof_material.albedo_color == roof_source.albedo_color, "Imported roof material was not copied into the merged mesh")
        var wall_geometry := walls.mesh.get_faces()
        var roof_geometry := roofs.mesh.get_faces()
        var node_count: int = entry.root.get_child_count()
        streamer.set_surface_materials()
        _check(walls.mesh.surface_get_material(0) is ShaderMaterial and roofs.mesh.surface_get_material(0) is ShaderMaterial, "Clearing imported overrides did not restore declared fallbacks")
        _check(walls.mesh.get_faces() == wall_geometry and roofs.mesh.get_faces() == roof_geometry and entry.root.get_child_count() == node_count, "Changing art materials changed registered geometry or created per-building nodes")
        streamer.set_surface_materials(wall_source, roof_source)
        _check(entry.body.collision_layer == 1, "Nearby building collision was not active")
        streamer.update_world(760.0, 10.0, true)
        await _wait_idle(streamer)
        _check(entry.body.collision_layer == 0 and entry.collider.shape == null, "Distant visible building retained a physics BVH")
        streamer.update_world(10.0, 10.0, true)
        await _wait_idle(streamer)
        _check(entry.body.collision_layer == 1 and entry.collider.shape != null, "Approaching a cell did not restore near collision")
        var before: Vector3 = entry.root.position
        var shift: Vector3 = coordinates.rebase(1000.25, 2000.5)
        streamer.rebase_by(shift)
        _check(entry.root.position.is_equal_approx(before + shift), "Origin rebase did not shift building roots exactly once")
        var world: PackedFloat64Array = coordinates.local_to_world(entry.root.position)
        _check(absf(world[0]) < 0.001 and absf(world[2]) < 0.001, "Building origin changed canonical coordinates")
    streamer.update_world(40970.0, 10.0, true)
    await _wait_idle(streamer)
    _check(streamer._loaded.size() == 1 and streamer._loaded.has("160:0"), "Far warp did not cancel/unload old content")
    _check(streamer._jobs.size() <= streamer.max_io_jobs and streamer._loaded.size() <= streamer.max_loaded_cells, "Streamer resource bounds were exceeded")
    var address: Dictionary = streamer._address(Vector2i(-1, -17))
    _check(address.tile == Vector2i(-1, -2) and address.local == Vector2i(15, 15), "Negative cell addressing truncates instead of flooring")
    var broken := FileAccess.open(root_path + "/broken.ymb", FileAccess.WRITE)
    broken.store_buffer("YMB1".to_ascii_buffer())
    broken.store_32(1)
    broken.store_16(0)
    broken.store_16(0)
    broken.store_32(0)
    broken.store_32(99)
    broken.close()
    _check(BuildingScript._read_cell(root_path + "/broken.ymb", Vector2i.ZERO).has("error"), "Malformed pack index was accepted")
    streamer.quality = "Performance"
    _check(streamer.draw_distance == 450.0 and streamer.max_loaded_cells == 64, "Graphics quality did not bound building visibility/residency")
    if streamer._loaded.has("160:0"):
        var walls := streamer._loaded["160:0"].root.get_node("Walls") as MeshInstance3D
        _check(is_equal_approx(walls.visibility_range_end, streamer.draw_distance + streamer.cell_size), "Imported material bypassed live mesh visibility settings")
        _check(walls.mesh.surface_get_material(0) is StandardMaterial3D, "Travel discarded the supplied imported wall material")
    print("YARDMAN_BUILDING_STREAMER_TEST %s cells=1 meshes=1 collision=1 cancel=1 rebase=1 bounds=1 corruption=1 imported_materials=1 art_geometry_invariance=1 clockwise_normals=1 inferred_hip_roof=1 source_roof_massing=1 elevated_parts=1 source_heights_courtyards_preserved=1" % ("PASS" if failures == 0 else "FAIL"))
    streamer.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)