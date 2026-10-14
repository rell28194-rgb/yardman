shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

// GLES-safe road path: preserves sourced asphalt/gravel and inferred markings
// while removing derivative-heavy filtering and the eight-lane fragment loop.
uniform bool unpaved = false;
uniform sampler2D reference_albedo : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_detail : source_color, repeat_enable, filter_linear_mipmap;
uniform bool has_reference_albedo = false;
uniform bool has_reference_detail = false;
uniform float visibility_distance = 2200.0;
varying float camera_distance;

float cheap_hash(vec2 p) {
    vec2 f = fract(p * vec2(0.1031, 0.11369));
    f += dot(f, f.yx + 19.19);
    return fract(f.x * f.y * 23.31);
}

void vertex() {
    camera_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
    Z_CLIP_SCALE = 0.99997;
}

void fragment() {
    float range_fade = smoothstep(visibility_distance * 0.82, visibility_distance, camera_distance);
    if (cheap_hash(floor(FRAGCOORD.xy * 0.5)) < range_fade) {
        discard;
    }
    float width = max(COLOR.r * 64.0, 1.0);
    float grain = cheap_hash(floor(UV * 8.0));
    vec3 base = unpaved ? vec3(0.34, 0.275, 0.18) : vec3(0.205, 0.217, 0.225);
    base *= 0.95 + grain * 0.08;
    if (has_reference_albedo) {
        vec3 reference_color = texture(reference_albedo, UV / 8.0).rgb;
        base = clamp(reference_color * (unpaved ? 1.08 : 2.18), vec3(0.055), vec3(0.46));
        if (has_reference_detail) {
            float detail = dot(texture(reference_detail, UV / 3.0).rgb, vec3(0.2126, 0.7152, 0.0722));
            base *= clamp(0.90 + detail * 0.55, 0.88, 1.18);
        }
    }
    float edge_distance = max(0.0, width * 0.5 - abs(UV.y));
    float shoulder = 1.0 - smoothstep(0.0, 0.34, edge_distance);
    base = mix(base, unpaved ? vec3(0.40, 0.33, 0.22) : vec3(0.27, 0.265, 0.245), shoulder * 0.22);

    int paint = int(round(COLOR.g * 2.0));
    float dash = 1.0 - step(3.2, mod(UV.x, 8.5));
    float line = 0.0;
    if (!unpaved && paint > 0) {
        // The safe path keeps the principal centre marking. High-tier Vulkan
        // expands multi-lane separators with derivative-aware antialiasing.
        line = (1.0 - smoothstep(0.045, 0.085, abs(UV.y))) * dash;
        line *= smoothstep(4.0, 9.0, min(UV2.x, UV2.y));
    }
    ALBEDO = mix(base, vec3(0.82, 0.815, 0.76), line * 0.80);
    ROUGHNESS = unpaved ? 0.98 : 0.90;
    SPECULAR = 0.20;
    METALLIC = 0.0;
}
