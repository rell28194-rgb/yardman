extends SceneTree

const Runtime = preload("res://scripts/hydrology_audio_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("HYDROLOGY_AUDIO_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var geometry := {
        "0:0": {
            "segments": PackedVector4Array([
                Vector4(0.0, 0.0, 10.0, 0.0),
                Vector4(20.0, 5.0, 20.0, 15.0),
            ]),
            "half_widths": PackedFloat32Array([1.0, 2.0]),
        }
    }
    var near := Runtime.nearest_info_from_geometry(geometry, Vector2(5.0, 3.0), 130.0)
    if near.is_empty() or absf(float(near.distance) - 2.0) > 0.001:
        _fail("nearest river edge distance incorrect")
        return
    if (near.point as Vector2).distance_to(Vector2(5.0, 0.0)) > 0.001:
        _fail("nearest river point incorrect")
        return
    if int(near.segments_checked) != 2:
        _fail("segment budget accounting incorrect")
        return
    if not Runtime.nearest_info_from_geometry(geometry, Vector2(500.0, 500.0), 130.0).is_empty():
        _fail("far water should be inaudible")
        return
    var stream := Runtime.build_water_stream()
    if stream == null or stream.mix_rate != 22050 or stream.stereo:
        _fail("water stream format incorrect")
        return
    if stream.data.size() != (22050 + 1) * 2:
        _fail("water stream size incorrect: %d" % stream.data.size())
        return
    if stream.data.decode_s16(0) != stream.data.decode_s16(stream.data.size() - 2):
        _fail("water loop endpoints are not seamless")
        return
    var runtime := Runtime.new()
    root.add_child(runtime)
    await process_frame
    var debug: Dictionary = runtime.debug_state()
    if int(debug.voices) != 1 or absf(float(debug.max_distance_m) - 130.0) > 0.001:
        _fail("audio voice budget changed")
        return
    print("YARDMAN_HYDROLOGY_AUDIO_RUNTIME_PASS voices=1 max_distance=130 segments_tested=2 stream_hz=22050 loop=seamless")
    runtime.queue_free()
    await process_frame
    await process_frame
    quit(0)
