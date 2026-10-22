extends SceneTree

const UIRuntime = preload("res://scripts/beta1_ui_audio_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_UI_AUDIO_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var contract := UIRuntime.asset_contract()
    if str(contract.get("file", "")) != "ui_click.wav":
        _fail("recovered UI click filename drifted")
        return
    if str(contract.get("hud_path", "")) != "YardmanHUD/GameHUD":
        _fail("UI audio escaped the GameHUD scope")
        return
    if not bool(contract.get("touch_controls_excluded", false)):
        _fail("touch driving controls are no longer explicitly excluded")
        return
    if int(contract.get("shared_players", 0)) != 1 or int(contract.get("max_polyphony", 0)) != 1:
        _fail("UI feedback allocated multiple players/polyphony")
        return
    if float(contract.get("volume_db", 0.0)) > -14.0:
        _fail("UI click mix is too loud")
        return
    if bool(contract.get("game_audio_voice_budget_mutation", true)) \
            or bool(contract.get("input_behavior_mutation", true)):
        _fail("UI feedback gained gameplay/audio-budget authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    var layer := CanvasLayer.new()
    layer.name = "YardmanHUD"
    root.add_child(layer)
    var hud := Control.new()
    hud.name = "GameHUD"
    layer.add_child(hud)
    var menu_button := Button.new()
    hud.add_child(menu_button)
    var nested := Control.new()
    hud.add_child(nested)
    var close_button := Button.new()
    nested.add_child(close_button)
    var touch := Control.new()
    touch.name = "TouchControls"
    layer.add_child(touch)
    var gas := Button.new()
    touch.add_child(gas)

    if not UIRuntime.eligible_control(menu_button, hud) or not UIRuntime.eligible_control(close_button, hud):
        _fail("GameHUD buttons were rejected")
        return
    if UIRuntime.eligible_control(gas, hud):
        _fail("touch driving button became eligible for UI click feedback")
        return
    if UIRuntime.eligible_control(Control.new(), hud):
        _fail("non-button control became eligible")
        return

    layer.queue_free()
    print("YARDMAN_BETA1_UI_AUDIO_RUNTIME_TEST PASS shared_player=1 polyphony=1 gamehud=1 nested=1 touch_excluded=1 game_voice_budget=0 input_mutation=0 fallback=1")
    quit(0)
