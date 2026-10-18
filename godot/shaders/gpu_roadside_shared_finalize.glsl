#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer CounterBuffer {
    uint near_count;
    uint far_count;
    uint grass_count;
    uint reserved;
} counters;
layout(set = 0, binding = 1, std430) buffer NearCommandBuffer { uint data[]; } near_commands;
layout(set = 0, binding = 2, std430) buffer FarCommandBuffer { uint data[]; } far_commands;
layout(set = 0, binding = 3, std430) buffer GrassCommandBuffer { uint data[]; } grass_commands;
layout(set = 0, binding = 4, std430) readonly buffer SurfaceCountBuffer { uvec4 data; } surfaces;

void main() {
    uint surface = gl_GlobalInvocationID.x;
    if (surface < surfaces.data.x) {
        near_commands.data[surface * 5u + 1u] = counters.near_count;
    }
    if (surface < surfaces.data.y) {
        far_commands.data[surface * 5u + 1u] = counters.far_count;
    }
    if (surface < surfaces.data.z) {
        grass_commands.data[surface * 5u + 1u] = counters.grass_count;
    }
}
