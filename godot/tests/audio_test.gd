extends SceneTree

const AudioScript = preload("res://scripts/game_audio.gd")
const Profiles = preload("res://scripts/vehicle_audio_profiles.gd")
const References = preload("res://scripts/reference_assets.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("AUDIO_TEST: " + message)

func _run() -> void:
    for profile_id in ["crown_v6", "mark_x_v6", "port_royal_flat6"]:
        _check(Profiles.has(profile_id), "Missing production acoustic profile %s" % profile_id)
    var audio = AudioScript.new()
    root.add_child(audio)
    audio.configure("Ultra", 0.6)
    audio.configure("Balanced", 0.6)
    _check(audio.get_child_count() == 10 and audio.debug_state().voices == 10, "Reconfiguration changed the bounded ten-voice vehicle mix")
    for player in audio.get_children():
        var stream := player.stream as AudioStreamWAV
        _check(stream != null and stream.format == AudioStreamWAV.FORMAT_16_BITS and not stream.stereo, "Voice PCM format is invalid")
        _check(stream != null and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "Voice is not a bounded cached loop")
        if stream == null:
            continue
        _check(stream.loop_begin == 0 and stream.loop_end * 2 == stream.data.size(), "Loop sample range exceeds PCM data")
        _check(stream.data.decode_s16(0) == stream.data.decode_s16(stream.data.size() - 2), "Loop endpoints are discontinuous")
        var energy := 0.0
        var maximum := 0
        for byte in range(0, stream.data.size(), 2):
            var sample := stream.data.decode_s16(byte)
            energy += absf(float(sample))
            maximum = maxi(maximum, absi(sample))
        _check(energy > 10000.0 and maximum < 32768, "%s voice is empty or invalid" % player.name)
        _check(player.max_polyphony == 1 and not player.playing, "Voice started before an active world state")

    var state := {"audio_profile": "crown_v6", "driving": true, "speed_mps": 0.0, "rpm": 720.0,
        "on_road": true, "walk_speed": 0.0, "ready": true, "menu_open": false, "throttle": 0.0, "slip_angle_deg": 0.0}
    audio.update_state(1.0 / 60.0, state)
    await process_frame
    _check(audio.debug_state().audio_profile == "crown_v6", "Crown acoustic profile was not applied")
    _check(audio.engine_idle.playing and not audio.engine_high.playing and not audio.footsteps.playing, "Idle vehicle did not select the idle engine layer")
    var crown_stream: AudioStream = audio.engine_high.stream
    var idle_pitch: float = audio.engine_idle.pitch_scale

    state.rpm = 6100.0
    state.speed_mps = 38.0
    state.throttle = 0.86
    for frame in range(120):
        audio.update_state(1.0 / 60.0, state)
    var road_pitch: float = audio.road_roll.pitch_scale
    _check(audio.engine_idle.pitch_scale >= idle_pitch, "RPM response moved idle pitch in the wrong direction")
    _check(audio.engine_high.playing and audio.exhaust.playing and audio.transmission.playing and audio.road_roll.playing, "Loaded Crown did not engage high-load, exhaust, transmission and rolling layers")
    _check(audio.engine_high.volume_db <= -10.0 and audio.exhaust.volume_db <= -10.0 and audio.wind.volume_db < audio.engine_high.volume_db, "Driving mix exceeds its output ceiling or wind dominates the powertrain")

    state.slip_angle_deg = 18.0
    audio.update_state(1.0 / 60.0, state)
    _check(audio.tire_scrub.playing, "High road slip did not engage tire scrub")
    state.slip_angle_deg = 0.0
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.tire_scrub.playing, "Tire scrub stayed active without meaningful slip")

    state.audio_profile = "mark_x_v6"
    audio.update_state(1.0 / 60.0, state)
    _check(audio.debug_state().audio_profile == "mark_x_v6", "Mark X acoustic profile switch failed")
    _check(audio.engine_high.stream != crown_stream, "Crown and Mark X still share the same synthesized engine bank")
    var mark_stream: AudioStream = audio.engine_high.stream
    state.audio_profile = "port_royal_flat6"
    audio.update_state(1.0 / 60.0, state)
    _check(audio.debug_state().audio_profile == "port_royal_flat6", "Port Royal acoustic profile switch failed")
    _check(audio.engine_high.stream != mark_stream, "Mark X and Port Royal still share the same synthesized engine bank")

    state.on_road = false
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.road_roll.playing and audio.offroad_roll.playing and audio.offroad_roll.pitch_scale < road_pitch, "Grass did not switch to lower-pitch offroad rolling")
    state.driving = false
    state.walk_speed = 4.5
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.engine_idle.playing and not audio.engine_high.playing and not audio.road_roll.playing and not audio.offroad_roll.playing and audio.footsteps.playing, "On-foot movement did not switch away from driving layers")
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
    _check(not audio.engine_idle.playing and not audio.engine_high.playing and not audio.wind.playing, "Inactive streaming world did not silence audio")
    state.ready = true
    audio.set_volume(0.0)
    audio.update_state(1.0 / 60.0, state)
    _check(not audio.engine_idle.playing and not audio.engine_high.playing and not audio.wind.playing, "Zero master volume did not stop voices")

    var builds_before_second: int = int(audio.debug_state().cache_build_count)
    var second = AudioScript.new()
    root.add_child(second)
    second.configure()
    second.set_vehicle_audio_profile("port_royal_flat6")
    _check(second.engine_high.stream == audio.engine_high.stream, "A second scene did not reuse cached Port Royal PCM")
    _check(int(second.debug_state().cache_build_count) == builds_before_second, "A second scene rebuilt already-cached PCM")
    state.rpm = NAN
    state.speed_mps = INF
    state.audio_profile = "port_royal_flat6"
    second.update_state(1.0 / 60.0, state)
    _check(is_finite(second.engine_idle.pitch_scale) and is_finite(second.engine_high.pitch_scale), "Invalid runtime telemetry corrupted audio pitch")

    var road_reference := References.audio("road_roll_loop.wav", true) as AudioStreamWAV
    if road_reference != null:
        _check(second.road_roll.stream.data == road_reference.data, "Available permitted road rolling reference PCM was not preserved")
    audio.queue_free()
    second.queue_free()
    await process_frame
    await process_frame
    _check(AudioScript._stream_cache.is_empty(), "Cached PCM outlived all audio owners")
    print("YARDMAN_AUDIO_TEST %s profiles=3 voices=10 load_layers=1 transmission=1 scrub=1 grass=1 footsteps=1 cache_reuse=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
