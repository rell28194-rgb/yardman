#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer SphereBuffer {
    vec4 data[];
} spheres;

layout(set = 0, binding = 1, std430) readonly buffer PlaneBuffer {
    vec4 data[];
} planes;

layout(set = 0, binding = 2, std430) writeonly buffer VisibilityBuffer {
    uint data[];
} visibility;

layout(set = 0, binding = 3, std430) readonly buffer ParamsBuffer {
    uint count;
} params;

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= params.count) {
        return;
    }

    vec4 sphere = spheres.data[index];
    uint is_visible = 1u;
    for (uint plane_index = 0u; plane_index < 6u; ++plane_index) {
        vec4 plane = planes.data[plane_index];
        float signed_distance = dot(plane.xyz, sphere.xyz) + plane.w;
        if (signed_distance < -sphere.w) {
            is_visible = 0u;
            break;
        }
    }
    visibility.data[index] = is_visible;
}
