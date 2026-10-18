#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer SphereBuffer {
    vec4 data[];
} spheres;

layout(set = 0, binding = 1, std430) readonly buffer PlaneBuffer {
    vec4 data[];
} planes;

layout(set = 0, binding = 2, std430) readonly buffer ParamsBuffer {
    uint count;
} params;

layout(set = 0, binding = 3, std430) writeonly buffer MultiMeshBuffer {
    vec4 rows[];
} multimesh;

layout(set = 0, binding = 4, std430) buffer CommandBuffer {
    uint data[];
} command;

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= params.count) {
        return;
    }

    vec4 sphere = spheres.data[index];
    for (uint plane_index = 0u; plane_index < 6u; ++plane_index) {
        vec4 plane = planes.data[plane_index];
        if (dot(plane.xyz, sphere.xyz) + plane.w < -sphere.w) {
            return;
        }
    }

    // For an indexed, single-surface MultiMesh command.data[1] is instanceCount.
    // Atomic compaction means the scene renderer can consume only visible rows.
    uint slot = atomicAdd(command.data[1], 1u);
    uint row = slot * 3u;
    multimesh.rows[row + 0u] = vec4(1.0, 0.0, 0.0, sphere.x);
    multimesh.rows[row + 1u] = vec4(0.0, 1.0, 0.0, sphere.y);
    multimesh.rows[row + 2u] = vec4(0.0, 0.0, 1.0, sphere.z);
}
