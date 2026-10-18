extends RefCounted
class_name YardmanGPUDrivenCapabilities

# Fail-closed capability inspection for the experimental GPU-driven renderer.
# A renderer name alone is not enough: Yardman requires the Mobile/Vulkan path,
# a live global RenderingDevice, and the exact indirect MultiMesh bridge APIs.
const REQUIRED_APIS := PackedStringArray([
    "get_rendering_device",
    "call_on_render_thread",
    "multimesh_get_buffer_rd_rid",
    "multimesh_get_command_buffer_rd_rid",
])

static func snapshot() -> Dictionary:
    var method := RenderingServer.get_current_rendering_method()
    var driver := RenderingServer.get_current_rendering_driver_name().to_lower()
    var method_ok := method == "mobile"
    var driver_ok := driver == "vulkan"
    var missing := PackedStringArray()
    for api_name in REQUIRED_APIS:
        if not RenderingServer.has_method(api_name):
            missing.append(api_name)
    var api_ok := missing.is_empty()

    var rd_available := false
    if method_ok and driver_ok and api_ok:
        var rd: Variant = RenderingServer.get_rendering_device()
        rd_available = rd is RenderingDevice

    var candidate := method_ok and driver_ok and api_ok and rd_available
    var reason := ""
    if not method_ok:
        reason = "rendering_method"
    elif not driver_ok:
        reason = "rendering_driver"
    elif not api_ok:
        reason = "missing_api"
    elif not rd_available:
        reason = "rendering_device"

    return {
        "gpu_driven_candidate": candidate,
        "fallback_required": not candidate,
        "rendering_method": method,
        "rendering_driver": driver,
        "rendering_device_available": rd_available,
        "indirect_api_available": api_ok,
        "missing_apis": missing,
        "fallback_reason": reason,
    }
