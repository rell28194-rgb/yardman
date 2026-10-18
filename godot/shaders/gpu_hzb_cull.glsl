#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer PyramidBuffer {
    float depth[];
} pyramid;
layout(set = 0, binding = 1, std430) readonly buffer LevelBuffer {
    uvec4 level[];
} levels;
layout(set = 0, binding = 2, std430) readonly buffer CandidateBuffer {
    float data[];
} candidates;
layout(set = 0, binding = 3, std430) writeonly buffer VisibilityBuffer {
    uint visible[];
} output_flags;
layout(set = 0, binding = 4, std430) readonly buffer ParamsBuffer {
    uvec4 data;
} params;

const uint CANDIDATE_STRIDE = 5u;
const float DEPTH_BIAS_M = 0.05;

void main() {
    uint index = gl_GlobalInvocationID.x;
    uint candidate_count = params.data.x;
    uint base_width = params.data.y;
    uint base_height = params.data.z;
    uint level_count = params.data.w;
    if (index >= candidate_count) {
        return;
    }

    uint base = index * CANDIDATE_STRIDE;
    float min_x_f = candidates.data[base + 0u];
    float min_y_f = candidates.data[base + 1u];
    float max_x_f = candidates.data[base + 2u];
    float max_y_f = candidates.data[base + 3u];
    float near_depth = candidates.data[base + 4u];

    if (near_depth <= 0.0 || max_x_f < 0.0 || max_y_f < 0.0
            || min_x_f >= float(base_width) || min_y_f >= float(base_height)) {
        output_flags.visible[index] = 1u;
        return;
    }

    float min_x_clamped = clamp(min_x_f, 0.0, float(base_width - 1u));
    float min_y_clamped = clamp(min_y_f, 0.0, float(base_height - 1u));
    float max_x_clamped = clamp(max_x_f, 0.0, float(base_width - 1u));
    float max_y_clamped = clamp(max_y_f, 0.0, float(base_height - 1u));

    uint chosen_level = level_count - 1u;
    uvec4 chosen = levels.level[chosen_level];
    uint chosen_x0 = 0u;
    uint chosen_y0 = 0u;
    uint chosen_x1 = 0u;
    uint chosen_y1 = 0u;

    for (uint level_index = 0u; level_index < level_count; level_index++) {
        uvec4 meta = levels.level[level_index];
        uint level_width = meta.y;
        uint level_height = meta.z;
        float scale_x = float(base_width) / float(level_width);
        float scale_y = float(base_height) / float(level_height);
        uint x0 = min(uint(floor(min_x_clamped / scale_x)), level_width - 1u);
        uint y0 = min(uint(floor(min_y_clamped / scale_y)), level_height - 1u);
        uint x1 = min(uint(floor(max_x_clamped / scale_x)), level_width - 1u);
        uint y1 = min(uint(floor(max_y_clamped / scale_y)), level_height - 1u);
        if ((x1 - x0) <= 1u && (y1 - y0) <= 1u) {
            chosen_level = level_index;
            chosen = meta;
            chosen_x0 = x0;
            chosen_y0 = y0;
            chosen_x1 = x1;
            chosen_y1 = y1;
            break;
        }
    }

    if (chosen_level == level_count - 1u && chosen_x1 == 0u && chosen_y1 == 0u) {
        float scale_x = float(base_width) / float(chosen.y);
        float scale_y = float(base_height) / float(chosen.z);
        chosen_x0 = min(uint(floor(min_x_clamped / scale_x)), chosen.y - 1u);
        chosen_y0 = min(uint(floor(min_y_clamped / scale_y)), chosen.z - 1u);
        chosen_x1 = min(uint(floor(max_x_clamped / scale_x)), chosen.y - 1u);
        chosen_y1 = min(uint(floor(max_y_clamped / scale_y)), chosen.z - 1u);
    }

    float maximum_depth = 0.0;
    for (uint y = chosen_y0; y <= chosen_y1; y++) {
        for (uint x = chosen_x0; x <= chosen_x1; x++) {
            maximum_depth = max(maximum_depth,
                pyramid.depth[chosen.x + y * chosen.y + x]);
        }
    }

    bool definitely_occluded = maximum_depth + DEPTH_BIAS_M < near_depth;
    output_flags.visible[index] = definitely_occluded ? 0u : 1u;
}
