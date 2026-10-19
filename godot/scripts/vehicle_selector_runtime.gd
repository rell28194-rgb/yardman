extends CanvasLayer
class_name YardmanVehicleSelectorRuntime

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const SAVE_PATH := "user://yardman/vehicle-selection.json"

var _game: Node
var _controller
var _vehicle_ids: Array[String] = []
var _button: Button
var _panel: PanelContainer
var _options: OptionButton
var _status: Label
var _current_id := Catalog.DEFAULT_ID

func attach(game: Node) -> void:
    _game = game
    _controller = game.get("vehicle") if game != null else null
    layer = 40
    _build_ui()
    _populate()
    var saved := _load_saved_id()
    var initial := saved if Catalog.has(saved) else Catalog.DEFAULT_ID
    if not _apply_vehicle(initial, false):
        _apply_vehicle(Catalog.DEFAULT_ID, false)

func _build_ui() -> void:
    _button = Button.new()
    _button.text = "CARS"
    _button.position = Vector2(18, 18)
    _button.size = Vector2(132, 44)
    _button.focus_mode = Control.FOCUS_NONE
    _button.pressed.connect(func() -> void: _panel.visible = not _panel.visible)
    add_child(_button)

    _panel = PanelContainer.new()
    _panel.position = Vector2(18, 70)
    _panel.size = Vector2(360, 196)
    _panel.visible = false
    add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 8)
    _panel.add_child(column)

    var title := Label.new()
    title.text = "VEHICLE FLEET"
    title.add_theme_font_size_override("font_size", 18)
    column.add_child(title)

    _options = OptionButton.new()
    _options.custom_minimum_size = Vector2(330, 44)
    _options.focus_mode = Control.FOCUS_NONE
    column.add_child(_options)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 8)
    column.add_child(actions)

    var apply := Button.new()
    apply.text = "Use selected car"
    apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    apply.focus_mode = Control.FOCUS_NONE
    apply.pressed.connect(_apply_selected)
    actions.add_child(apply)

    var close := Button.new()
    close.text = "Close"
    close.focus_mode = Control.FOCUS_NONE
    close.pressed.connect(func() -> void: _panel.visible = false)
    actions.add_child(close)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status.text = "Dedicated vehicle assets only."
    column.add_child(_status)

func _populate() -> void:
    _vehicle_ids.clear()
    _options.clear()
    for raw_id in Catalog.production_ids():
        var vehicle_id := str(raw_id)
        if not Catalog.has(vehicle_id):
            continue
        var profile: Dictionary = Catalog.profile(vehicle_id)
        _vehicle_ids.append(vehicle_id)
        _options.add_item(str(profile.get("display_name", vehicle_id)))
    _select_id(Catalog.DEFAULT_ID)

func _apply_selected() -> void:
    if _options.selected < 0 or _options.selected >= _vehicle_ids.size():
        return
    _apply_vehicle(_vehicle_ids[_options.selected], true)

func _apply_vehicle(vehicle_id: String, persist: bool) -> bool:
    if _controller == null or not Catalog.has(vehicle_id):
        return false
    if absf(float(_controller.get("speed_mps"))) > 0.5:
        _status.text = "Stop the car before changing vehicles."
        return false

    var previous := _current_id
    _controller.call("apply_profile", vehicle_id)
    var visual = _controller.get("visual")
    var missing := visual == null or bool(visual.get_meta("yardman_hero_asset_missing_or_invalid", false)) \
        or bool(visual.get_meta("yardman_procedural_vehicle_fallback", false))
    if missing:
        if previous != vehicle_id and Catalog.has(previous):
            _controller.call("apply_profile", previous)
        _select_id(previous)
        _status.text = "%s is not available as a dedicated asset in this build." % str(Catalog.profile(vehicle_id).get("display_name", vehicle_id))
        return false

    _current_id = vehicle_id
    _select_id(vehicle_id)
    var profile: Dictionary = Catalog.profile(vehicle_id)
    var display_name := str(profile.get("display_name", vehicle_id))
    _button.text = "CARS · " + display_name
    _status.text = display_name
    if _game != null:
        _game.set_meta("yardman_selected_vehicle_id", vehicle_id)
    if persist:
        _save_id(vehicle_id)
    return true

func _select_id(vehicle_id: String) -> void:
    var index := _vehicle_ids.find(vehicle_id)
    if index >= 0:
        _options.select(index)

func _load_saved_id() -> String:
    if not FileAccess.file_exists(SAVE_PATH):
        return Catalog.DEFAULT_ID
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
    if not parsed is Dictionary:
        return Catalog.DEFAULT_ID
    return str(parsed.get("vehicle_id", Catalog.DEFAULT_ID))

func _save_id(vehicle_id: String) -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify({"vehicle_id": vehicle_id}))
