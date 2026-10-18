#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) buffer PyramidBuffer {
    float depth[];
} pyramid;
layout(set = 0, binding = 1, std430) readonly buffer ParamsBuffer {
    uvec4 data[2];
} params;

void main() {
    uint dst_x = gl_GlobalInvocationID.x;
    uint dst_y = gl_GlobalInvocationID.y;
    uint src_offset = params.data[0].x;
    uint src_width = params.data[0].y;
    uint src_height = params.data[0].z;
    uint dst_offset = params.data[0].w;
    uint dst_width = params.data[1].x;
    uint dst_height = params.data[1].y;
    if (dst_x >= dst_width || dst_y >= dst_height) {
        return;
    }

    uint src_x = dst_x * 2u;
    uint src_y = dst_y * 2u;
    float maximum_depth = 0.0;
    for (uint oy = 0u; oy < 2u; oy++) {
        uint y = min(src_y + oy, src_height - 1u);
        for (uint ox = 0u; ox < 2u; ox++) {
            uint x = min(src_x + ox, src_width - 1u);
            maximum_depth = max(maximum_depth, pyramid.depth[src_offset + y * src_width + x]);
        }
    }
    pyramid.depth[dst_offset + dst_y * dst_width + dst_x] = maximum_depth;
}
