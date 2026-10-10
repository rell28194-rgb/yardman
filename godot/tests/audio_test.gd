extends SceneTree

const AudioScript = preload("res://scripts/game_audio.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("AUDIO_TEST: " + message)

func _run() -> void:
    var audio = AudioScript.new()
    root.add_child(audio)
    audio.configure("Ultra", 0.6)
    audio.configure("Balanced", 0.6)
    _check(audio.get_child_count() == 4 and audio.debug_state().voices == 4, "Reconfiguration exceeded the four-voice budget")
    for player in audio.get_children():
        var stream := player.stream as AudioStreamWAV
        _check(stream != null and stream.format == AudioStreamWAV.FORMAT_16_BITS and not stream.stereo, "Voice PCM format is invalid")
        _check(stream.mix_rate == 22050 and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "Voice is not a bounded cached loop")
        _check(stream.loop_begin == 0 and stream.loop_end * 2 == stream.data.size(), "Loop sample range exceeds PCM data")
        _check(stream.data.decode_s16(0) == stream.data.decode_s16(stream.data.size() - 2), "Loop endpoints are discontinuous")
        var energy := 0.0
        var maximum := 0
        for byte in range(0, stream.data.size(), 2):
            var sample := stream.data.decode_s16(byte)
            energy += absf(float(sample))
            maximum = maxi(maximum, absi(sample))
        _check(energy > 10000.0 and maximum < 30000, "Voice is empty or its source PCM clips")
        _check(player.max_polyphony == 1 and not player.playing, "Voice started before an active world state")
    var state := {"driving": true, "speed_mps": 0.0, "rpm": 900.0, "on_road": true, "walk_speed": 0.0, "ready": true, "menu_open": false}
    audio.update_state(1.0 / 60.0, state)
    await process_frame
    _check(audio.engine.playing and not audio.footsteps.playing, "Idle driving did not select engine exclusively")
    var idle_pitch: float = audio.engine.pitch_scale
    state.rpm = 6000.0
    state.speed_mps = 35.0
    audio.update_state(1.0 / 60.0, state)
    _check(audio.engine.pitch_scale > idle_pitch and audio.engine.pitch_scale < 1.0, "RPM/gear transition is not smoothed")
    for frame in range(120):
        audio.update_state(1.0 / 60.0, state)
    var road_pitch: float = audio.road_roll.pitch_scale
    _check(audio.engine.pitch_scale > 3.0 and audio.engine.pitch_scale <= 3.4 and audio.road_roll.playing, "Speed/RPM did not influence engine and road voices within bounds")
    _check(audio.engine.volume_db <= -14.0 and audio.road_roll.volume_db <= -14.0 and audio.wind.volume_db < audio.engine.volume_db, "Driving mix exceeds its tame volume or wind dominates")
    state.on_road = false
    audio.update_state(1.0 / 60.0, state)
    _check(audio.road_roll.pitch_scale < road_pitch, "Grass did not change roll timbre")
    state.driving = false
    state.walk_speed = 4.5
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.engine.playing and not audio.road_roll.playing and audio.footsteps.playing, "On-foot movement did not switch away from driving voices")
    state.walk_speed = 0.0
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.footsteps.playing, "Standing player continued footsteps")
    state.driving = true
    state.menu_open = true
    audio.update_state(1.0 / 60.0, state)
    for player in audio.get_children():
        _check(not player.playing and player.volume_db == -80.0, "Menu did not silence a voice")
    state.menu_open = false
    state.ready = false
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.engine.playing and not audio.footsteps.playing and not audio.wind.playing, "Inactive streaming world did not silence audio")
    state.ready = true
    audio.set_volume(0.0)
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.engine.playing and not audio.wind.playing, "Zero master volume did not stop voices")
    var second = AudioScript.new()
    root.add_child(second)
    second.configure()
    _check(second.engine.stream == audio.engine.stream and second.debug_state().cache_build_count == 1, "A second scene rebuilt cached PCM")
    state.rpm = NAN
    state.speed_mps = INF
    second.update_state(1.0 / 60.0, state)
    _check(is_finite(second.engine.pitch_scale), "Invalid runtime telemetry corrupted audio pitch")
    print("YARDMAN_AUDIO_TEST %s cached_pcm=1 loop_seams=1 voices=4 rpm_smoothing=1 grass=1 footsteps=1 menu_silence=1" % ("PASS" if failures == 0 else "FAIL"))
    audio.queue_free()
    second.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
