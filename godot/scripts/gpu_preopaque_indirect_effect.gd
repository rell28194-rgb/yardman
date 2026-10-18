extends CompositorEffect
class_name YardmanGPUPreOpaqueIndirectEffect

const COMMAND_INSTANCE_COUNT_OFFSET := 4
const COMMAND_WORD_BYTES := 4

var _rd: RenderingDevice
var _mutex := Mutex.new()
var _multimesh := RID()
var _requested_count := 0
var _request_serial := 0
var _applied_serial := 0
var _applied_count := -1
var _callback_count := 0
var _last_write_ok := false

func _init() -> void:
    effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
    _rd = RenderingServer.get_rendering_device()

func set_multimesh(multimesh: RID) -> void:
    _mutex.lock()
    _multimesh = multimesh
    _mutex.unlock()

func clear_multimesh() -> void:
    _mutex.lock()
    _multimesh = RID()
    _mutex.unlock()

func request_instance_count(instance_count: int) -> int:
    _mutex.lock()
    _requested_count = maxi(instance_count, 0)
    _request_serial += 1
    var serial := _request_serial
    _mutex.unlock()
    return serial

func state() -> Dictionary:
    _mutex.lock()
    var value := {
        "request_serial": _request_serial,
        "applied_serial": _applied_serial,
        "applied_count": _applied_count,
        "callback_count": _callback_count,
        "last_write_ok": _last_write_ok,
    }
    _mutex.unlock()
    return value

func _render_callback(callback_type: EffectCallbackType, _render_data: RenderData) -> void:
    if _rd == null or callback_type != EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
        return

    _mutex.lock()
    var multimesh := _multimesh
    var requested_count := _requested_count
    var requested_serial := _request_serial
    _mutex.unlock()

    var ok := false
    if multimesh.is_valid():
        var command_buffer := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
        if command_buffer.is_valid():
            var bytes := PackedInt32Array([requested_count]).to_byte_array()
            _rd.buffer_update(command_buffer, COMMAND_INSTANCE_COUNT_OFFSET,
                COMMAND_WORD_BYTES, bytes)
            ok = true

    _mutex.lock()
    _callback_count += 1
    _last_write_ok = ok
    if ok:
        _applied_serial = requested_serial
        _applied_count = requested_count
    _mutex.unlock()
