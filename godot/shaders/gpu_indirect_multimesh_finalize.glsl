#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer CounterBuffer {
    uint visible_count;
} counter;

layout(set = 0, binding = 1, std430) buffer CommandBuffer {
    uint data[];
} commands;

layout(set = 0, binding = 2, std430) readonly buffer ParamsBuffer {
    uint surface_count;
} params;

void main() {
    uint surface = gl_GlobalInvocationID.x;
    if (surface >= params.surface_count) {
        return;
    }

    // Godot's indexed indirect MultiMesh command is five uints per surface:
    // indexCount, instanceCount, firstIndex, vertexOffset, firstInstance.
    commands.data[surface * 5u + 1u] = counter.visible_count;
}
