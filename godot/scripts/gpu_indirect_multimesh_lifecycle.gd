extends RefCounted
class_name YardmanGPUIndirectMultiMeshLifecycle

# Godot 4.7.2's RD MultiMesh free path resets the indirect command-buffer RID
# without freeing that StorageBuffer. Upstream fix: godotengine/godot#121641.
# Keep this exact-version shim isolated so a future engine update can remove it
# instead of carrying an unsafe double-free workaround indefinitely.
static func requires_472_command_buffer_workaround() -> bool:
    var version := Engine.get_version_info()
    return int(version.get("major", -1)) == 4 \
        and int(version.get("minor", -1)) == 7 \
        and int(version.get("patch", -1)) == 2

# Must be called on the render thread. The MultiMesh's command buffer is owned
# by RenderingServer, except that Godot 4.7.2 loses ownership without freeing it
# during destruction. Free it exactly once before handing the MultiMesh back to
# the affected engine free path.
static func free_on_render_thread(multimesh: RID) -> Dictionary:
    if not multimesh.is_valid():
        return {"freed": false, "manual_command_free": false}

    var manual_command_free := false
    if requires_472_command_buffer_workaround():
        var rd := RenderingServer.get_rendering_device()
        if rd != null:
            var command_buffer := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
            if command_buffer.is_valid():
                rd.free_rid(command_buffer)
                manual_command_free = true

    RenderingServer.free_rid(multimesh)
    return {"freed": true, "manual_command_free": manual_command_free}
