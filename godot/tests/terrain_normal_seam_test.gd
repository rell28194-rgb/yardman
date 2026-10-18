extends SceneTree

const Terrain = preload("res://scripts/terrain_streamer.gd")
var failures := 0

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _plane_job(origin_x: float, origin_z: float, slope_x: float, slope_z: float) -> Dictionary:
    var heights := PackedFloat32Array()
    for z in range(3):
        for x in range(3):
            heights.append(100.0 + slope_x * (origin_x + x * 64.0) + slope_z * (origin_z + z * 64.0))
    return {"heights": heights, "coast": {"mask": PackedByteArray([1, 1, 1, 1])},
        "vertices": PackedVector3Array(), "normals": PackedVector3Array(),
        "colors": PackedColorArray(), "indices": PackedInt32Array()}

func _initialize() -> void:
    var terrain := Terrain.new()
    terrain.resolution = 3
    terrain.spacing = 64.0
    for slope in [Vector2(0.5, 0.25), Vector2(-0.5, 0.25), Vector2.ZERO]:
        var expected := Vector3(-slope.x, 1.0, -slope.y).normalized()
        var jobs: Array[Dictionary] = []
        for origin in [Vector2.ZERO, Vector2(128, 0), Vector2(0, 128)]:
            var job := _plane_job(origin.x, origin.y, slope.x, slope.y)
            for row in range(3):
                terrain._append_height_row(job, row)
            jobs.append(job)
            for index in range(9):
                _check(job.normals[index].distance_to(expected) < 0.00001,
                    "Planar DEM normal differs at vertex %d, slope %s" % [index, slope])
                _check(job.colors[index].is_equal_approx(terrain._height_color(job.heights[index], slope.length())),
                    "Planar DEM slope colour changes at a tile boundary")
        for offset in range(3):
            _check(jobs[0].normals[offset * 3 + 2].distance_to(jobs[1].normals[offset * 3]) < 0.00001,
                "East/west tile normals disagree")
            _check(jobs[0].normals[6 + offset].distance_to(jobs[2].normals[offset]) < 0.00001,
                "North/south tile normals disagree")
    terrain.free()
    print("TERRAIN NORMAL SEAM: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
    quit(0 if failures == 0 else 1)
