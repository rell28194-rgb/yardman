#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer SphereBuffer { vec4 data[]; } spheres;
layout(set = 0, binding = 1, std430) readonly buffer ParamsBuffer { uint count; } params;
layout(set = 0, binding = 2, std430) writeonly buffer MultiMeshBuffer { float data[]; } multimesh_buffer;
layout(set = 0, binding = 3, std430) buffer CommandBuffer { uint data[]; } command_buffer;

bool sphere_visible(vec4 sphere) {
    return sphere.x + 50.0 >= -sphere.w && -sphere.x + 50.0 >= -sphere.w
        && sphere.y + 50.0 >= -sphere.w && -sphere.y + 50.0 >= -sphere.w
        && sphere.z + 50.0 >= -sphere.w && -sphere.z + 50.0 >= -sphere.w;
}

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= params.count) return;
    vec4 sphere = spheres.data[index];
    if (!sphere_visible(sphere)) return;

    uint slot = atomicAdd(command_buffer.data[1], 1u);
    uint base = slot * 12u;
    multimesh_buffer.data[base + 0u] = 1.0;
    multimesh_buffer.data[base + 1u] = 0.0;
    multimesh_buffer.data[base + 2u] = 0.0;
    multimesh_buffer.data[base + 3u] = sphere.x;
    multimesh_buffer.data[base + 4u] = 0.0;
    multimesh_buffer.data[base + 5u] = 1.0;
    multimesh_buffer.data[base + 6u] = 0.0;
    multimesh_buffer.data[base + 7u] = sphere.y;
    multimesh_buffer.data[base + 8u] = 0.0;
    multimesh_buffer.data[base + 9u] = 0.0;
    multimesh_buffer.data[base + 10u] = 1.0;
    multimesh_buffer.data[base + 11u] = sphere.z;
}
