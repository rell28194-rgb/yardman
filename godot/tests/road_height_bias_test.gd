extends SceneTree

const Streamer = preload("res://scripts/road_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_HEIGHT_BIAS_TEST: " + message)

func _run() -> void:
    var stream = Streamer.new()
    # Real Kingston node osm:3192369425 joins these independent source ways.
    # The former 32-bucket scheme puts both in bucket 6.
    var first := "w313324811"
    var second := "w313324820"
    _check(first.hash() % 32 == second.hash() % 32, "Regression pair no longer exercises the old exact tie")
    var a: float = stream._source_way_height_bias(first)
    var b: float = stream._source_way_height_bias(second)
    _check(absf(a - b) > 0.001, "Kingston intersection retains an equal/near-equal render offset")
    _check(Vector3(0.0, 18.0 + a, 0.0).y != Vector3(0.0, 18.0 + b, 0.0).y,
        "Regression pair collides after float32 vertex conversion")
    for source_id in [first, second, "w1", "w2", "w9999999999", "legacy"]:
        var bias: float = stream._source_way_height_bias(source_id)
        _check(bias >= 0.14 and bias <= 0.171, "Source-way overlay leaves the existing 0.14–0.171 m range")
        _check(bias == stream._source_way_height_bias(source_id), "Source-way offset is not deterministic")

    # Mesh emission must preserve canonical metre UVs, the terrain normal and
    # the same offset across logical pieces and neighboring tile origins.
    var polygon: Array = [[4095.0, 18.0, 40.0], [4097.0, 18.5, 40.0], [4097.0, 18.5, 44.0], [4095.0, 18.0, 44.0]]
    var canonical_uv: Array = [[120.0, -2.0], [122.0, -2.0], [122.0, 2.0], [120.0, 2.0]]
    var segment: Array = [4095.0, 42.0, 4097.0, 42.0, 4.0, 4, 0, first + ":0:osm:1:osm:2", 0, 18.0, 18.5,
        polygon, canonical_uv, 0, 1, 0.0, 0.0, 122.0]
    var outputs: Array = []
    for tile in [Vector2i.ZERO, Vector2i(1, 0)]:
        var vertices := PackedVector3Array()
        var indices := PackedInt32Array()
        var normals := PackedVector3Array()
        var uvs := PackedVector2Array()
        var uv2s := PackedVector2Array()
        var colors := PackedColorArray()
        stream._append_segment(vertices, indices, normals, uvs, uv2s, colors, segment, tile)
        outputs.append(vertices)
        _check(vertices.size() == 4 and indices.size() == 6, "Height bias changed ribbon geometry counts")
        for i in range(vertices.size()):
            _check(absf(vertices[i].y - (float(polygon[i][1]) + a)) < 0.000003,
                "Mesh vertex does not use source-way offset")
            _check(uvs[i] == Vector2(canonical_uv[i][0], canonical_uv[i][1]), "Canonical metre UV changed")
            _check(normals[i].dot(Vector3(-0.25, 1.0, 0.0).normalized()) > 0.99999, "Terrain normal changed")
        segment[7] = first + ":1:osm:2:osm:3"
    for i in range(outputs[0].size()):
        _check(outputs[0][i].y == outputs[1][i].y, "Same source way has a vertical seam between graph pieces/tiles")
        _check(absf(outputs[0][i].x - outputs[1][i].x - 4096.0) < 0.000001, "Tile-local metre registration changed")
    stream.free()
    print("YARDMAN_ROAD_HEIGHT_BIAS_TEST %s old_pair_bucket=%s bias_a=%.9f bias_b=%.9f same_way_seam=1 canonical_uv=1 terrain_normal=1" %
        ["PASS" if failures == 0 else "FAIL", first.hash() % 32, a, b])
    quit(0 if failures == 0 else 1)
