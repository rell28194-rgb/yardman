extends SceneTree

# A full-size interface fixture. These frames inspect the HUD, not game art.
const ControlsScript = preload("res://scripts/touch_controls.gd")
const HUDScript = preload("res://scripts/hud.gd")
var output_dir := ""
var controls
var hud
var background: ColorRect
var failures := 0
var draw_count := 0
var hud_draw_count := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("CONTROLS_RENDER_TEST: " + message)

func _capture(filename: String) -> void:
    for frame in range(4):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    _check(picture != null and not picture.is_empty(), "Missing rendered interface frame")
    if picture != null and not picture.is_empty():
        _check(picture.save_png(output_dir.path_join(filename + ".png")) == OK, "Could not save " + filename)

func _run() -> void:
    output_dir = OS.get_environment("YARDMAN_HUD_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("res://build/hud-captures")
    DirAccess.make_dir_recursive_absolute(output_dir)
    root.size = Vector2i(1280, 720)
    background = ColorRect.new()
    background.color = Color(0.18, 0.28, 0.23)
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.add_child(background)
    controls = ControlsScript.new()
    root.add_child(controls)
    controls._touch_seen = true
    controls.draw.connect(func() -> void: draw_count += 1)
    hud = HUDScript.new()
    hud.configure(["St. Ann", "St. Mary", "Kingston", "Manchester", "Hanover"], ["Performance", "Balanced", "Quality", "Ultra", "Custom"])
    root.add_child(hud)
    hud.draw.connect(func() -> void: hud_draw_count += 1)
    hud.attach_controls(controls)
    hud.select_quality("Ultra")
    hud.set_status({"parish": "St. Ann", "ready": true, "can_interact": true, "driving": true, "speed_kmh": 68.0, "gear": "D", "time_hour": 10.5})
    hud.set_radar_paths([PackedVector2Array([Vector2(-170, -180), Vector2(0, 0), Vector2(120, 170)]), PackedVector2Array([Vector2(-180, 50), Vector2(180, 50)])], Vector2.ZERO, 0.0)
    await _capture("hud-driving")
    var idle_count := draw_count
    var idle_hud_count := hud_draw_count
    for frame in range(8):
        controls.driving = true
        hud.set_status({"time_hour": 10.5001})
        await process_frame
    _check(draw_count == idle_count, "Idle touch controls regenerated their custom canvas")
    _check(hud_draw_count == idle_hud_count, "Identical visible HUD state regenerated its custom canvas")
    controls.driving = false
    hud.set_status({"driving": false})
    controls._press(0, Vector2(158, 607))
    controls._drag(0, Vector2(188, 560), Vector2(30, -47))
    await _capture("hud-walking")
    controls.clear_input()
    controls.driving = true
    hud.set_status({"driving": true})
    controls.apply_settings({"steering_mode": "Buttons"})
    await _capture("hud-buttons")
    controls.apply_settings({"steering_mode": "Wheel"})
    await _capture("hud-wheel")
    controls.apply_settings({"steering_mode": "Stick"})
    hud.set_menu_open(true)
    await _capture("hud-settings-top")
    hud._menu_scroll.scroll_vertical = int(hud._menu_scroll.get_v_scroll_bar().max_value)
    await _capture("hud-settings-bottom")
    hud.set_menu_open(false)
    root.size = Vector2i(960, 540)
    root.content_scale_size = Vector2i(960, 540)
    controls.apply_settings({"button_scale": 1.4})
    await _capture("hud-compact-large-controls")
    hud.set_menu_open(true)
    await _capture("hud-compact-settings")
    print("YARDMAN_CONTROLS_RENDER_TEST %s gl_frames=8 idle_redraw=0" % ("PASS" if failures == 0 else "FAIL"))
    hud.queue_free()
    controls.queue_free()
    background.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
