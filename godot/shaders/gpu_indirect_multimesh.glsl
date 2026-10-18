#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer SphereBuffer {
    vec4 data[];
} spheres;

layout(set = 0, binding = 1, std430) readonly buffer SourceInstanceBuffer {
    float data[];
} source_instances;

layout(set = 0, binding = 2, std430) writeonly buffer DestinationMultiMeshBuffer {
    float data[];
} destination_instances;

layout(set = 0, binding = 3, std430) buffer CounterBuffer {
    uint visible_count;
} counter;

layout(set = 0, binding = 4, std430) readonly buffer ParamsBuffer {
    uint count;
    uint stride_floats;
} params;

bool sphere_visible(vec4 sphere) {
    return sphere.x + 50.0 >= -sphere.w && -sphere.x + 50.0 >= -sphere.w
        && sphere.y + 50.0 >= -sphere.w && -sphere.y + 50.0 >= -sphere.w
        && sphere.z + 50.0 >= -sphere.w && -sphere.z + 50.0 >= -sphere.w;
}

void main() {
    uint source_index = gl_GlobalInvocationID.x;
    if (source_index >= params.count) {
        return;
    }
    if (!sphere_visible(spheres.data[source_index])) {
        return;
    }

    // Atomic compaction deliberately does not promise stable slot ordering.
    // Source identity must live in instance/custom data rather than in the
    // compacted destination slot number.
    uint destination_index = atomicAdd(counter.visible_count, 1u);
    uint source_base = source_index * params.stride_floats;
    uint destination_base = destination_index * params.stride_floats;
    for (uint component = 0u; component < params.stride_floats; ++component) {
        destination_instances.data[destination_base + component] = source_instances.data[source_base + component];
    }
}
