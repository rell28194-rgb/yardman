extends SceneTree

const Ambience = preload("res://scripts/environment_audio_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("ENVIRONMENT_AUDIO_TEST: " + message)

func _run() -> void:
    var balanced := Ambience.budget_for("Balanced", 0, "mobile")
    var hot := Ambience.budget_for("Balanced", 5, "mobile")
    var gles := Ambience.budget_for("Ultra", 0, "gl_compatibility")
    _check(int(balanced.voices) <= Ambience.MAX_AMBIENT_VOICES, "balanced ambience exceeded hard voice ceiling")
    _check(int(hot.voices) < int(balanced.voices), "thermal policy did not reduce ambience voices")
    _check(int(hot.voices) >= 2, "thermal policy removed environmental ambience")
    _check(int(gles.voices) <= 4, "GLES ambience voice budget exceeded fallback cap")

    var morning := Ambience.mix_for_context(8.0, 0.0, 0.0, 0.1, 0.0, false)
    var midnight := Ambience.mix_for_context(0.0, 0.0, 0.0, 0.1, 0.0, false)
    var coast := Ambience.mix_for_context(14.0, 0.0, 1.0, 0.0, 0.0, false)
    var town := Ambience.mix_for_context(20.0, 0.0, 0.0, 1.0, 0.0, false)
    var storm := Ambience.mix_for_context(12.0, 1.0, 0.0, 0.0, 0.0, false)
    _check(float(morning.birds) > float(midnight.birds), "day cycle did not favor morning birds")
    _check(float(midnight.insects) > float(morning.insects), "night cycle did not favor insects")
    _check(float(coast.ocean) > 0.60, "coastal context did not raise ocean ambience")
    _check(float(town.settlement) > 0.45, "live settlement context did not raise activity ambience")
    _check(float(storm.wind) > float(morning.wind), "weather did not raise wind ambience")

    var selected := Ambience.select_layers({"ocean": 0.9, "wind": 0.4, "birds": 0.2, "insects": 0.1, "settlement": 0.8}, 2)
    _check(selected.size() == 2, "voice selector ignored ambience budget")
    _check(selected[0] == "ocean" and selected[1] == "settlement", "voice selector did not retain strongest layers")

    _check(Ambience.activity_factor_from_counts(0, 20, 0, 20) == 0.0, "empty road context reported settlement activity")
    _check(Ambience.activity_factor_from_counts(20, 20, 20, 20) > 0.99, "full live population did not reach settlement activity ceiling")

    var mask := PackedByteArray()
    mask.resize(16)
    mask.fill(1)
    mask[1 * 4 + 1] = 2
    var payload := {"mask": mask}
    var near_coast := Ambience.coast_factor_from_payload(payload, Vector2i.ZERO, 96.0, 96.0, 256.0, 64.0, 5, 620.0)
    var far_coast := Ambience.coast_factor_from_payload(payload, Vector2i.ZERO, 2450.0, 2450.0, 256.0, 64.0, 5, 620.0)
    _check(near_coast > 0.80, "registered coastline mask did not produce near-shore ambience")
    _check(far_coast < 0.01, "coast ambience leaked beyond the registered shoreline search radius")

    if failures == 0:
        print("YARDMAN_ENVIRONMENT_AUDIO_TEST PASS clock=1 weather=1 coast=1 activity=1 voice_budget=1 thermal=1")
        quit()
    else:
        print("YARDMAN_ENVIRONMENT_AUDIO_TEST FAIL failures=%d" % failures)
        quit(1)
