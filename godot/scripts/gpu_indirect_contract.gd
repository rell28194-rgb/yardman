extends RefCounted
class_name YardmanGPUIndirectContract

# Contract for the currently validated GPU-written MultiMesh layout.
# The compute shader writes three vec4 transform rows per compacted instance,
# so unsupported MultiMesh layouts must fail closed before any buffer is bound.
const TRANSFORM_STRIDE_FLOATS := 12
const INDIRECT_COMMAND_STRIDE_WORDS := 5
const INSTANCE_COUNT_WORD := 1

static func validate(mesh: Mesh, transform_format: int,
        use_colors: bool, use_custom_data: bool) -> Dictionary:
    if mesh == null:
        return _invalid("mesh")
    var surface_count := mesh.get_surface_count()
    if surface_count != 1:
        return _invalid("surface_count", surface_count)
    if transform_format != RenderingServer.MULTIMESH_TRANSFORM_3D:
        return _invalid("transform_format", surface_count)
    if use_colors:
        return _invalid("instance_colors", surface_count)
    if use_custom_data:
        return _invalid("instance_custom_data", surface_count)
    return {
        "valid": true,
        "fallback_required": false,
        "reason": "",
        "surface_count": surface_count,
        "transform_stride_floats": TRANSFORM_STRIDE_FLOATS,
        "command_stride_words": INDIRECT_COMMAND_STRIDE_WORDS,
        "instance_count_word": INSTANCE_COUNT_WORD,
    }

static func _invalid(reason: String, surface_count: int = 0) -> Dictionary:
    return {
        "valid": false,
        "fallback_required": true,
        "reason": reason,
        "surface_count": surface_count,
        "transform_stride_floats": TRANSFORM_STRIDE_FLOATS,
        "command_stride_words": INDIRECT_COMMAND_STRIDE_WORDS,
        "instance_count_word": INSTANCE_COUNT_WORD,
    }
