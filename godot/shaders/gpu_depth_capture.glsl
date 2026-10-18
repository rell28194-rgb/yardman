#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(set = 0, binding = 1, std430) writeonly buffer DepthCaptureBuffer {
    float data[];
} capture;

layout(push_constant, std430) uniform Params {
    mat4 inv_projection;
    vec2 raster_size;
    vec2 padding;
} params;

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(params.raster_size);
    if (pixel.x >= size.x || pixel.y >= size.y) {
        return;
    }

    vec2 uv = (vec2(pixel) + vec2(0.5)) / params.raster_size;
    float raw_depth = texture(depth_texture, uv).r;
    vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
    vec4 view = params.inv_projection * vec4(ndc, 1.0);
    float linear_depth = 0.0;
    if (abs(view.w) > 1e-8) {
        linear_depth = max(0.0, -view.z / view.w);
    }

    uint index = uint(pixel.y * size.x + pixel.x) * 2u;
    capture.data[index + 0u] = raw_depth;
    capture.data[index + 1u] = linear_depth;
}
