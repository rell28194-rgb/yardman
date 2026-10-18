#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer PackedSourceBuffer {
    float data[];
} source_records;
layout(set = 0, binding = 1, std430) writeonly buffer NearBuffer {
    float data[];
} near_records;
layout(set = 0, binding = 2, std430) writeonly buffer FarBuffer {
    float data[];
} far_records;
layout(set = 0, binding = 3, std430) writeonly buffer GrassBuffer {
    float data[];
} grass_records;
layout(set = 0, binding = 4, std430) buffer CounterBuffer {
    uint near_count;
    uint far_count;
    uint grass_count;
    uint reserved;
} counters;
layout(set = 0, binding = 5, std430) readonly buffer ParamsBuffer {
    // x = source count, y = deterministic density budget in permille [0,1000].
    uvec4 data;
} params;
layout(set = 0, binding = 6, std430) readonly buffer RangeBuffer {
    vec4 data;
} ranges;

const uint SOURCE_STRIDE = 8u;
const uint DESTINATION_STRIDE = 20u;

uint stable_hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

bool density_selected(uint source_index) {
    uint budget = min(params.data.y, 1000u);
    return budget >= 1000u || (stable_hash(source_index) % 1000u) < budget;
}

bool sphere_visible(vec3 position, float radius) {
    return position.x + 50.0 >= -radius && -position.x + 50.0 >= -radius
        && position.y + 50.0 >= -radius && -position.y + 50.0 >= -radius
        && position.z + 50.0 >= -radius && -position.z + 50.0 >= -radius;
}

void write_transform(uint base, vec3 position, float yaw, float scale, uint layer) {
    float c = cos(yaw) * scale;
    float s = sin(yaw) * scale;
    if (layer == 0u) {
        near_records.data[base + 0u] = c;
        near_records.data[base + 1u] = 0.0;
        near_records.data[base + 2u] = s;
        near_records.data[base + 3u] = position.x;
        near_records.data[base + 4u] = 0.0;
        near_records.data[base + 5u] = scale;
        near_records.data[base + 6u] = 0.0;
        near_records.data[base + 7u] = position.y;
        near_records.data[base + 8u] = -s;
        near_records.data[base + 9u] = 0.0;
        near_records.data[base + 10u] = c;
        near_records.data[base + 11u] = position.z;
    } else if (layer == 1u) {
        far_records.data[base + 0u] = c;
        far_records.data[base + 1u] = 0.0;
        far_records.data[base + 2u] = s;
        far_records.data[base + 3u] = position.x;
        far_records.data[base + 4u] = 0.0;
        far_records.data[base + 5u] = scale;
        far_records.data[base + 6u] = 0.0;
        far_records.data[base + 7u] = position.y;
        far_records.data[base + 8u] = -s;
        far_records.data[base + 9u] = 0.0;
        far_records.data[base + 10u] = c;
        far_records.data[base + 11u] = position.z;
    } else {
        grass_records.data[base + 0u] = c;
        grass_records.data[base + 1u] = 0.0;
        grass_records.data[base + 2u] = s;
        grass_records.data[base + 3u] = position.x;
        grass_records.data[base + 4u] = 0.0;
        grass_records.data[base + 5u] = scale;
        grass_records.data[base + 6u] = 0.0;
        grass_records.data[base + 7u] = position.y;
        grass_records.data[base + 8u] = -s;
        grass_records.data[base + 9u] = 0.0;
        grass_records.data[base + 10u] = c;
        grass_records.data[base + 11u] = position.z;
    }
}

void write_payload(uint base, vec3 custom_data, uint layer) {
    if (layer == 0u) {
        near_records.data[base + 12u] = 1.0;
        near_records.data[base + 13u] = 1.0;
        near_records.data[base + 14u] = 1.0;
        near_records.data[base + 15u] = 1.0;
        near_records.data[base + 16u] = custom_data.x;
        near_records.data[base + 17u] = custom_data.y;
        near_records.data[base + 18u] = custom_data.z;
        near_records.data[base + 19u] = 1.0;
    } else if (layer == 1u) {
        far_records.data[base + 12u] = 1.0;
        far_records.data[base + 13u] = 1.0;
        far_records.data[base + 14u] = 1.0;
        far_records.data[base + 15u] = 1.0;
        far_records.data[base + 16u] = custom_data.x;
        far_records.data[base + 17u] = custom_data.y;
        far_records.data[base + 18u] = 0.5;
        far_records.data[base + 19u] = 1.0;
    } else {
        grass_records.data[base + 12u] = 1.0;
        grass_records.data[base + 13u] = 1.0;
        grass_records.data[base + 14u] = 1.0;
        grass_records.data[base + 15u] = 1.0;
        grass_records.data[base + 16u] = custom_data.x;
        grass_records.data[base + 17u] = custom_data.y;
        grass_records.data[base + 18u] = custom_data.z;
        grass_records.data[base + 19u] = 1.0;
    }
}

void write_layer(uint slot, vec3 position, float yaw, float scale, vec3 custom_data, uint layer) {
    uint base = slot * DESTINATION_STRIDE;
    write_transform(base, position, yaw, scale, layer);
    write_payload(base, custom_data, layer);
}

void main() {
    uint source_index = gl_GlobalInvocationID.x;
    uint count = params.data.x;
    if (source_index >= count || !density_selected(source_index)) {
        return;
    }

    uint base = source_index * SOURCE_STRIDE;
    vec3 position = vec3(
        source_records.data[base + 0u],
        source_records.data[base + 1u],
        source_records.data[base + 2u]);
    float yaw = source_records.data[base + 3u];
    float scale = source_records.data[base + 4u];
    vec3 custom_data = vec3(
        source_records.data[base + 5u],
        source_records.data[base + 6u],
        source_records.data[base + 7u]);

    float radius = max(0.25, scale * 2.0);
    if (!sphere_visible(position, radius)) {
        return;
    }

    float distance_xz = length(position.xz);
    if (distance_xz <= ranges.data.x) {
        uint slot = atomicAdd(counters.near_count, 1u);
        write_layer(slot, position, yaw, scale, custom_data, 0u);
    }
    if (distance_xz >= ranges.data.y && distance_xz <= ranges.data.z) {
        uint slot = atomicAdd(counters.far_count, 1u);
        write_layer(slot, position, yaw, scale, custom_data, 1u);
    }
    if (distance_xz <= ranges.data.w) {
        uint slot = atomicAdd(counters.grass_count, 1u);
        write_layer(slot, position, yaw, scale * 1.2, custom_data, 2u);
    }
}
