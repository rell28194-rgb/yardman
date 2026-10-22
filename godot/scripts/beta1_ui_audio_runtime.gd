extends Node
class_name YardmanBeta1UIAudioRuntime

# Owner-private recovered UI feedback. One shared player is scoped to GameHUD;
# touch driving controls are a sibling and are deliberately excluded so GAS,
# BRAKE, steering and handbrake do not become noisy gameplay click sources.
const References = preload("res://scripts/reference_assets.gd")
const CLICK_ASSET := "ui_click.wav"
const CLICK_VOLUME_DB := -18.0
const MAX_POLYPHONY := 1

var _hud: Control
var _player: AudioStreamPlayer
var _connected: Dictionary = {}
var _bind_clock := 0.0

func _ready() -> void:
    call_deferred("_try_bind")

func _process(delta: float) -> void:
    if _hud != null and is_instance_valid(_hud):
        set_process(false)
        return
    _bind_clock += delta
    if _bind_clock >= 0.5:
        _bind_clock = 0.0
        _try_bind()

func _exit_tree() -> void:
    if get_tree() != null and get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.disconnect(_on_node_added)
    _connected.clear()

func _try_bind() -> void:
    var root := get_parent()
    if root == null:
        return
    var candidate := root.get_node_or_null("YardmanHUD/GameHUD") as Control
    if candidate == null:
        return
    _hud = candidate
    var stream := References.audio(CLICK_ASSET, false)
    if stream == null:
        # Public/source-only builds keep fully functional silent UI feedback.
        set_process(false)
        return
    _player = AudioStreamPlayer.new()
    _player.name = "RecoveredUIClick"
    _player.stream = stream
    _player.volume_db = CLICK_VOLUME_DB
    _player.max_polyphony = MAX_POLYPHONY
    add_child(_player)
    _connect_existing(_hud)
    if not get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.connect(_on_node_added)
    set_process(false)

func _connect_existing(root: Node) -> void:
    var stack: Array[Node] = [root]
    while not stack.is_empty():
        var node: Node = stack.pop_back()
        if node is BaseButton:
            _connect_button(node as BaseButton)
        for child: Node in node.get_children():
            stack.append(child)

func _on_node_added(node: Node) -> void:
    if node is BaseButton and eligible_control(node, _hud):
        call_deferred("_connect_button_weak", weakref(node))

func _connect_button_weak(reference: WeakRef) -> void:
    var value: Variant = reference.get_ref()
    if value is BaseButton:
        _connect_button(value as BaseButton)

func _connect_button(button: BaseButton) -> void:
    if _player == null or not eligible_control(button, _hud):
        return
    var identity := button.get_instance_id()
    if _connected.has(identity):
        return
    _connected[identity] = true
    button.pressed.connect(_play_click)
    button.tree_exited.connect(func() -> void: _connected.erase(identity), CONNECT_ONE_SHOT)

func _play_click() -> void:
    if _player == null or _player.stream == null:
        return
    _player.stop()
    _player.play()

static func eligible_control(node: Node, hud_root: Control) -> bool:
    return node is BaseButton and hud_root != null and (node == hud_root or hud_root.is_ancestor_of(node))

static func asset_contract() -> Dictionary:
    return {
        "file": CLICK_ASSET,
        "hud_path": "YardmanHUD/GameHUD",
        "touch_controls_excluded": true,
        "shared_players": 1,
        "max_polyphony": MAX_POLYPHONY,
        "volume_db": CLICK_VOLUME_DB,
        "game_audio_voice_budget_mutation": false,
        "input_behavior_mutation": false,
        "asset_absent_fallback": true,
    }
