@static_unload
extends Node
class_name YardmanGameAudio

const References = preload("res://scripts/reference_assets.gd")
const Profiles = preload("res://scripts/vehicle_audio_profiles.gd")
const SAMPLE_RATE := 22050
const SILENT_DB := -80.0
const MAX_VOICES := 10
static var _stream_cache: Dictionary = {}
static var _cache_build_count := 0
static var _active_instances := 0

var engine_idle: AudioStreamPlayer
var engine_low: AudioStreamPlayer
var engine_high: AudioStreamPlayer
var exhaust: AudioStreamPlayer
var transmission: AudioStreamPlayer
var road_roll: AudioStreamPlayer
var offroad_roll: AudioStreamPlayer
var tire_scrub: AudioStreamPlayer
var footsteps: AudioStreamPlayer
var wind: AudioStreamPlayer
var quality := "Balanced"
var volume := 0.72
var _voices: Array[AudioStreamPlayer] = []
var _configured := false
var _audio_profile_id := Profiles.DEFAULT_ID
var _audio_profile: Dictionary = Profiles.profile(Profiles.DEFAULT_ID)
var _rpm := 900.0
var _load := 0.0
var _previous_speed := 0.0
var _last_driving := false
var _shifting := false
var _shift_mix := 0.0
var _gear_index := 0

func _ready() -> void:
    if not _configured:
        configure()

func configure(profile: String = "Balanced", default_volume: float = 0.72) -> void:
    quality = profile
    if not _configured:
        _prepare_common_streams()
        _prepare_profile_streams(_audio_profile_id)
        var bank: Dictionary = _stream_cache["vehicle:" + _audio_profile_id]
        var common: Dictionary = _stream_cache.common
        engine_idle = _make_voice("EngineIdle", bank.engine_idle)
        engine_low = _make_voice("EngineLow", bank.engine_low)
        engine_high = _make_voice("EngineHigh", bank.engine_high)
        exhaust = _make_voice("Exhaust", bank.exhaust)
        transmission = _make_voice("Transmission", common.transmission)
        road_roll = _make_voice("RoadRoll", common.road)
        offroad_roll = _make_voice("OffroadRoll", common.offroad)
        tire_scrub = _make_voice("TireScrub", common.tire_scrub)
        footsteps = _make_voice("Footsteps", common.footsteps)
        wind = _make_voice("Wind", common.wind)
        _configured = true
        _active_instances += 1
    set_volume(default_volume)

func _exit_tree() -> void:
    _silence()
    for player in _voices:
        player.stream = null
    if _configured:
        _active_instances = maxi(0, _active_instances - 1)
        _configured = false
    if _active_instances == 0:
        _stream_cache.clear()
        _cache_build_count = 0

func set_volume(value: float) -> void:
    volume = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0
    if volume <= 0.0001:
        _silence()

func set_vehicle_audio_profile(profile_id: String) -> void:
    var resolved := profile_id if Profiles.has(profile_id) else Profiles.DEFAULT_ID
    if resolved == _audio_profile_id and _configured:
        return
    _audio_profile_id = resolved
    _audio_profile = Profiles.profile(resolved)
    _rpm = clampf(_rpm, float(_audio_profile.idle_rpm), float(_audio_profile.redline_rpm))
    _prepare_profile_streams(resolved)
    if not _configured:
        return
    var bank: Dictionary = _stream_cache["vehicle:" + resolved]
    engine_idle.stream = bank.engine_idle
    engine_low.stream = bank.engine_low
    engine_high.stream = bank.engine_high
    exhaust.stream = bank.exhaust
    for player in [engine_idle, engine_low, engine_high, exhaust]:
        player.stop()
        player.volume_db = SILENT_DB

func update_state(delta: float, state: Dictionary) -> void:
    if not _configured:
        configure(quality, volume)
    var dt := clampf(delta, 0.001, 0.20) if is_finite(delta) else 0.016
    var controller := _current_vehicle_controller()
    var requested_profile := str(state.get("audio_profile", ""))
    if requested_profile.is_empty() and controller != null and controller.has_method("audio_profile"):
        requested_profile = str(controller.call("audio_profile"))
    if requested_profile.is_empty():
        requested_profile = _audio_profile_id
    set_vehicle_audio_profile(requested_profile)

    var active := bool(state.get("ready", false)) and not bool(state.get("menu_open", false))
    var driving := bool(state.get("driving", false))
    var speed := _finite_value(state.get("speed_mps", 0.0), -120.0, 120.0)
    var walk_speed := absf(_finite_value(state.get("walk_speed", 0.0), 0.0, 15.0))
    var desired_rpm := _finite_value(state.get("rpm", float(_audio_profile.idle_rpm)), 0.0, float(_audio_profile.redline_rpm) + 400.0)
    var acceleration := (absf(speed) - absf(_previous_speed)) / dt if _last_driving and driving else 0.0
    var desired_load := clampf(0.10 + maxf(acceleration, 0.0) / 7.5, 0.0, 1.0)
    if state.has("throttle"):
        desired_load = absf(_finite_value(state.throttle, -1.0, 1.0))
    var slip_angle := absf(_finite_value(state.get("slip_angle_deg", -1.0), -90.0, 90.0))
    if slip_angle < 0.0:
        slip_angle = 0.0
    var shifting := bool(state.get("shifting", false))
    var gear_index := clampi(int(state.get("gear_index", 0)), 0, 12)
    if controller != null:
        if not state.has("slip_angle_deg"):
            var controller_slip = controller.get("drift_angle_deg")
            if controller_slip != null:
                slip_angle = absf(_finite_value(controller_slip, -90.0, 90.0))
        if not state.has("shifting") and controller.has_method("is_shifting"):
            shifting = bool(controller.call("is_shifting"))
        if not state.has("gear_index") and controller.has_method("gear_index"):
            gear_index = clampi(int(controller.call("gear_index")), 0, 12)
    _shifting = shifting and driving
    _gear_index = gear_index
    var shift_response := 24.0 if _shifting else 11.0
    _shift_mix = lerpf(_shift_mix, 1.0 if _shifting else 0.0, 1.0 - exp(-dt * shift_response))
    _rpm = lerpf(_rpm, desired_rpm, 1.0 - exp(-dt * 8.5))
    _load = lerpf(_load, desired_load, 1.0 - exp(-dt * 9.0))
    _previous_speed = speed
    _last_driving = driving
    if not active or volume <= 0.0001:
        _silence()
        return

    var road_surface := bool(state.get("on_road", true))
    var speed_reference := 62.0
    var speed_fraction := clampf(absf(speed) / speed_reference, 0.0, 1.0)
    var idle_rpm := float(_audio_profile.idle_rpm)
    var redline_rpm := float(_audio_profile.redline_rpm)
    var rpm_fraction := clampf((_rpm - idle_rpm) / maxf(redline_rpm - idle_rpm, 1.0), 0.0, 1.0)
    var pitch_bias := float(_audio_profile.pitch_bias)

    var idle_mix := 1.0 - smoothstep(0.10, 0.34, rpm_fraction + _load * 0.10)
    var low_mix := smoothstep(0.04, 0.22, rpm_fraction + _load * 0.12) * (1.0 - smoothstep(0.70, 0.94, rpm_fraction))
    var high_mix := smoothstep(0.24, 0.68, rpm_fraction * 0.82 + _load * 0.46)
    var exhaust_mix := smoothstep(0.10, 0.52, _load) * smoothstep(0.04, 0.32, rpm_fraction + _load * 0.18)
    var shift_engine_gain := lerpf(1.0, 0.56, _shift_mix)
    var shift_engine_db := linear_to_db(maxf(shift_engine_gain, 0.05))

    var idle_pitch := clampf(pitch_bias * (0.82 + rpm_fraction * 0.72), 0.66, 1.72)
    var low_pitch := clampf(pitch_bias * (0.68 + rpm_fraction * 1.62), 0.62, 2.58)
    var high_pitch := clampf(pitch_bias * (0.72 + rpm_fraction * 1.82), 0.64, 2.90)
    var exhaust_pitch := clampf(pitch_bias * (0.76 + rpm_fraction * 1.36), 0.62, 2.35)
    _voice(engine_idle, driving and desired_rpm > 0.0 and idle_mix > 0.012,
        float(_audio_profile.idle_db) + linear_to_db(maxf(idle_mix, 0.012)), idle_pitch)
    _voice(engine_low, driving and desired_rpm > 0.0 and low_mix > 0.012,
        float(_audio_profile.low_db) + linear_to_db(maxf(low_mix, 0.012)) + _load * 2.0 + shift_engine_db, low_pitch)
    _voice(engine_high, driving and desired_rpm > 0.0 and high_mix > 0.012,
        float(_audio_profile.high_db) + linear_to_db(maxf(high_mix, 0.012)) + _load * 3.5 + shift_engine_db, high_pitch)
    _voice(exhaust, driving and desired_rpm > 0.0 and exhaust_mix > 0.012,
        float(_audio_profile.exhaust_db) + linear_to_db(maxf(exhaust_mix, 0.012)) + _load * 2.8 + shift_engine_db * 0.65, exhaust_pitch)

    var transmission_base := speed_fraction * smoothstep(0.10, 0.36, rpm_fraction + _load * 0.15)
    var shift_pulse := _shift_mix * (0.46 + minf(float(_gear_index), 7.0) * 0.035)
    var transmission_mix := maxf(transmission_base, shift_pulse)
    var transmission_pitch := clampf(0.68 + speed_fraction * 1.25 + rpm_fraction * 0.34 + _shift_mix * 0.22, 0.62, 2.55)
    _voice(transmission, driving and transmission_mix > 0.025,
        float(_audio_profile.transmission_db) + transmission_mix * 7.0 + _shift_mix * 2.2,
        transmission_pitch)

    var roll_pitch := clampf(0.66 + absf(speed) * 0.030, 0.62, 2.12)
    var roll_db := -42.0 + speed_fraction * 14.5
    _voice(road_roll, driving and road_surface and absf(speed) > 0.8, roll_db, roll_pitch)
    _voice(offroad_roll, driving and not road_surface and absf(speed) > 0.55,
        -38.5 + speed_fraction * 13.0, clampf(0.64 + absf(speed) * 0.021, 0.60, 1.72))

    var scrub_mix := clampf((slip_angle - 2.5) / 18.0, 0.0, 1.0) * smoothstep(3.5, 14.0, absf(speed))
    _voice(tire_scrub, driving and road_surface and scrub_mix > 0.035,
        -38.0 + scrub_mix * 13.0, clampf(0.82 + speed_fraction * 0.70 + scrub_mix * 0.18, 0.72, 1.75))

    var step_pitch := clampf(pow(maxf(walk_speed, 0.1) / 3.8, 0.35), 0.75, 1.65)
    var step_db := -32.0 + clampf(walk_speed / 8.0, 0.0, 1.0) * 5.0
    _voice(footsteps, not driving and walk_speed > 0.35, step_db, step_pitch)
    var ambient_speed := absf(speed) if driving else walk_speed
    _voice(wind, true, -51.0 + clampf(ambient_speed / 62.0, 0.0, 1.0) * 11.0,
        0.70 + clampf(ambient_speed / 62.0, 0.0, 1.0) * 0.36)

func debug_state() -> Dictionary:
    return {
        "voices": _voices.size(), "cache_build_count": _cache_build_count,
        "audio_profile": _audio_profile_id,
        "engine_idle_playing": engine_idle.playing if engine_idle != null else false,
        "engine_low_playing": engine_low.playing if engine_low != null else false,
        "engine_high_playing": engine_high.playing if engine_high != null else false,
        "exhaust_playing": exhaust.playing if exhaust != null else false,
        "transmission_playing": transmission.playing if transmission != null else false,
        "tire_scrub_playing": tire_scrub.playing if tire_scrub != null else false,
        "footsteps_playing": footsteps.playing if footsteps != null else false,
        "engine_idle_pitch": engine_idle.pitch_scale if engine_idle != null else 1.0,
        "engine_high_pitch": engine_high.pitch_scale if engine_high != null else 1.0,
        "engine_high_db": engine_high.volume_db if engine_high != null else SILENT_DB,
        "exhaust_db": exhaust.volume_db if exhaust != null else SILENT_DB,
        "transmission_db": transmission.volume_db if transmission != null else SILENT_DB,
        "transmission_pitch": transmission.pitch_scale if transmission != null else 1.0,
        "road_pitch": road_roll.pitch_scale if road_roll != null else 1.0,
        "rpm": _rpm, "load": _load, "volume": volume,
        "shifting": _shifting, "shift_mix": _shift_mix, "gear_index": _gear_index,
    }

func _current_vehicle_controller() -> Object:
    var scene := get_tree().current_scene if get_tree() != null else null
    if scene == null:
        return null
    var candidate = scene.get("vehicle")
    return candidate if candidate is Object else null

func _finite_value(value: Variant, low: float, high: float) -> float:
    var number := float(value) if value is float or value is int else 0.0
    return clampf(number, low, high) if is_finite(number) else 0.0

func _make_voice(voice_name: String, stream: AudioStreamWAV) -> AudioStreamPlayer:
    var player := AudioStreamPlayer.new()
    player.name = voice_name
    player.stream = stream
    player.volume_db = SILENT_DB
    player.max_polyphony = 1
    add_child(player)
    _voices.append(player)
    return player

func _voice(player: AudioStreamPlayer, enabled: bool, decibels: float, pitch: float) -> void:
    if not enabled:
        player.volume_db = SILENT_DB
        player.stop()
        return
    player.pitch_scale = clampf(pitch, 0.45, 3.40)
    player.volume_db = clampf(decibels + linear_to_db(maxf(volume, 0.0001)), SILENT_DB, -10.0)
    if not player.playing:
        player.play()

func _silence() -> void:
    for player in _voices:
        player.volume_db = SILENT_DB
        player.stop()

static func _prepare_common_streams() -> void:
    if _stream_cache.has("common"):
        return
    var common := {}
    for kind in ["transmission", "road", "offroad", "tire_scrub", "footsteps", "wind"]:
        common[kind] = _make_loop(kind, {}, 1.0)
    var mappings := {
        "road": "road_roll_loop.wav",
        "offroad": "grass_roll_loop.wav",
        "footsteps": "footsteps_loop.wav",
    }
    for kind in mappings:
        var reference := References.audio(str(mappings[kind]), true) as AudioStreamWAV
        if reference != null:
            common[kind] = reference
    _stream_cache.common = common
    _cache_build_count += 1

static func _prepare_profile_streams(profile_id: String) -> void:
    var resolved := profile_id if Profiles.has(profile_id) else Profiles.DEFAULT_ID
    var key := "vehicle:" + resolved
    if _stream_cache.has(key):
        return
    var profile := Profiles.profile(resolved)
    var bank := {}
    for layer in ["engine_idle", "engine_low", "engine_high", "exhaust"]:
        bank[layer] = _make_loop(layer, profile, 0.75)
    _stream_cache[key] = bank
    _cache_build_count += 1

static func _make_loop(kind: String, profile: Dictionary, seconds: float) -> AudioStreamWAV:
    var samples := int(round(seconds * SAMPLE_RATE)) + 1
    var pcm := PackedByteArray()
    pcm.resize(samples * 2)
    for index in range(samples):
        var t := seconds * float(index) / float(samples - 1)
        var value := _sample(kind, t, profile)
        pcm.encode_s16(index * 2, int(round(clampf(value, -0.88, 0.88) * 32767.0)))
    pcm.encode_s16((samples - 1) * 2, pcm.decode_s16(0))
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_16_BITS
    stream.mix_rate = SAMPLE_RATE
    stream.stereo = false
    stream.data = pcm
    stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
    stream.loop_begin = 0
    stream.loop_end = samples
    return stream

static func _sample(kind: String, t: float, profile: Dictionary) -> float:
    if kind.begins_with("engine") or kind == "exhaust":
        var base := float(profile.get("base_hz", 48.0))
        var h2 := float(profile.get("harmonic_2", 0.46))
        var h3 := float(profile.get("harmonic_3", 0.24))
        var h4 := float(profile.get("harmonic_4", 0.11))
        var rasp := float(profile.get("rasp", 0.06))
        var depth := float(profile.get("exhaust_depth", 0.42))
        var multiplier := 1.0
        var brightness := 1.0
        var modulation := 0.10
        if kind == "engine_low":
            multiplier = 1.08
            brightness = 1.12
            modulation = 0.075
        elif kind == "engine_high":
            multiplier = 1.18
            brightness = 1.38
            modulation = 0.055
        elif kind == "exhaust":
            multiplier = 0.62
            brightness = 0.72
            modulation = 0.13
        var f := base * multiplier
        var note := sin(TAU * f * t) * 0.28
        note += sin(TAU * f * 2.0 * t + 0.18) * h2 * 0.42 * brightness
        note += sin(TAU * f * 3.0 * t + 0.51) * h3 * 0.34 * brightness
        note += sin(TAU * f * 4.0 * t + 1.13) * h4 * 0.30 * brightness
        note += sin(TAU * f * 7.0 * t + 0.70) * rasp * 0.24 * brightness
        if kind == "exhaust":
            note += sin(TAU * f * 0.5 * t + 0.4) * depth * 0.22
        return note * (0.90 + modulation * sin(TAU * 4.0 * t))
    match kind:
        "transmission":
            return sin(TAU * 178.0 * t) * 0.10 + sin(TAU * 356.0 * t + 0.2) * 0.045 + sin(TAU * 534.0 * t + 1.1) * 0.022
        "road":
            var road_noise := 0.0
            var road_frequencies := [97.0, 211.0, 353.0, 607.0, 911.0, 1301.0, 1733.0]
            for harmonic in range(road_frequencies.size()):
                road_noise += sin(TAU * road_frequencies[harmonic] * t + float(harmonic) * 1.913) / (float(harmonic) + 2.0)
            return road_noise * 0.22
        "offroad":
            return (sin(TAU * 51.0 * t) * 0.17 + sin(TAU * 117.0 * t + 0.7) * 0.10 + sin(TAU * 337.0 * t + 2.0) * 0.055) * (0.78 + 0.22 * sin(TAU * 7.0 * t))
        "tire_scrub":
            var scrub := sin(TAU * 307.0 * t) * 0.09 + sin(TAU * 467.0 * t + 0.3) * 0.075
            scrub += sin(TAU * 719.0 * t + 1.2) * 0.052 + sin(TAU * 1031.0 * t + 2.1) * 0.032
            return scrub * (0.84 + 0.16 * sin(TAU * 13.0 * t))
        "footsteps":
            var strike := 0.0
            for start in [0.055, 0.555]:
                var elapsed: float = t - start
                if elapsed >= 0.0 and elapsed < 0.14:
                    var envelope := sin(PI * minf(elapsed / 0.008, 1.0) * 0.5) * exp(-elapsed * 34.0)
                    strike += envelope * (sin(TAU * 93.0 * elapsed) * 0.33 + sin(TAU * 317.0 * elapsed) * 0.10 + sin(TAU * 821.0 * elapsed) * 0.04)
            return strike
        "wind":
            return (sin(TAU * 29.0 * t) * 0.13 + sin(TAU * 47.0 * t + 0.4) * 0.095 + sin(TAU * 79.0 * t + 1.7) * 0.06 + sin(TAU * 131.0 * t + 2.4) * 0.04) * (0.8 + 0.2 * cos(TAU * 2.0 * t))
    return 0.0
