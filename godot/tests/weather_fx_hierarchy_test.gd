extends SceneTree

const Weather = preload("res://scripts/weather_fx_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("WEATHER_FX_HIERARCHY_TEST: " + message)
    quit(1)

func _run() -> void:
    var contract := Weather.weather_contract()
    var source: Dictionary = contract.get("source_reference", {})
    if int(source.get("RainNear", {}).get("max_live", 0)) != 1000 \
            or int(source.get("RainMiddle", {}).get("max_live", 0)) != 1500 \
            or int(source.get("RainFar", {}).get("max_live", 0)) != 2500:
        _fail("recovered near/middle/far source hierarchy drifted")
        return
    if int(source.get("RainMist", {}).get("max_live", 0)) != 200 \
            or int(source.get("MistAfterRain", {}).get("max_live", 0)) != 1000:
        _fail("recovered rain/post-rain mist reference drifted")
        return
    if int(contract.get("raw_source_live_total", 0)) != 5000:
        _fail("raw rain source count contract drifted")
        return
    if int(contract.get("max_draw_batches", 99)) != 2 or int(contract.get("rain_batches", 0)) != 1 \
            or int(contract.get("mist_batches", 0)) != 1:
        _fail("weather draw-batch budget changed")
        return
    if int(contract.get("max_drops", 9999)) > 640 or int(contract.get("max_mist", 999)) > 32:
        _fail("Android weather particle caps exceeded")
        return
    if bool(contract.get("runtime_geometry_authority", true)) or bool(contract.get("terrain_mutation", true)) \
            or bool(contract.get("foreign_texture_dependency", true)):
        _fail("weather reference gained world/terrain/foreign-texture authority")
        return

    var tiers := {0.0: 0, 0.5: 0, 1.0: 0}
    for index in range(100):
        var tier := Weather.rain_tier_for_index(index)
        if not tiers.has(tier):
            _fail("unexpected rain tier")
            return
        tiers[tier] += 1
    if int(tiers[0.0]) != 20 or int(tiers[0.5]) != 30 or int(tiers[1.0]) != 50:
        _fail("interleaved 20/30/50 tier relationship drifted")
        return

    var weather := Weather.new()
    root.add_child(weather)
    await process_frame
    var rain := weather.get_node_or_null("WeatherRainHierarchy") as MultiMeshInstance3D
    var mist := weather.get_node_or_null("WeatherRainMist") as MultiMeshInstance3D
    if rain == null or mist == null or rain.multimesh == null or mist.multimesh == null:
        _fail("weather batches were not constructed")
        return
    if rain.multimesh.instance_count != Weather.MAX_DROPS or mist.multimesh.instance_count != Weather.MAX_MIST:
        _fail("runtime instance allocation no longer matches bounded caps")
        return
    if rain.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
            or mist.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
        _fail("weather batch shadows were enabled")
        return

    weather._intensity = 0.78
    weather._after_rain = 0.78
    weather._update_rain(null, "Balanced", false)
    weather._update_mist(null, "Balanced", false)
    var wet_state := weather.debug_state()
    if int(wet_state.get("visible_drops", 0)) <= 180 or int(wet_state.get("visible_drops", 9999)) > 260:
        _fail("balanced rain budget is outside expected mobile range")
        return
    if int(wet_state.get("visible_mist", 0)) <= 0 or int(wet_state.get("visible_mist", 999)) > 10:
        _fail("balanced rain mist budget is outside expected mobile range")
        return

    weather._intensity = 0.0
    weather._after_rain = 0.70
    weather._update_mist(null, "Balanced", false)
    if int(weather.debug_state().get("visible_mist", 0)) <= 0:
        _fail("post-rain mist did not survive after rainfall ended")
        return

    var collisions := 0
    var stack: Array[Node] = [weather]
    while not stack.is_empty():
        var node: Node = stack.pop_back()
        if node is CollisionObject3D or node is CollisionShape3D:
            collisions += 1
        for child: Node in node.get_children():
            stack.append(child)
    if collisions != 0:
        _fail("weather hierarchy created collision")
        return

    weather.queue_free()
    await process_frame
    print("YARDMAN_WEATHER_FX_HIERARCHY_TEST PASS source_near=1000 source_mid=1500 source_far=2500 rain_batches=1 mist_batches=1 tiers=20_30_50 android_cap=1 post_rain=1 collision=0 terrain_mutation=0")
    quit(0)
