shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_burley, specular_schlick_ggx;

uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float motion_scale : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sky_tint : source_color = vec3(0.18, 0.26, 0.31);
varying float puddle_phase;
varying float puddle_alpha;

void vertex() {
    puddle_phase = INSTANCE_CUSTOM.r * 6.2831853;
    puddle_alpha = mix(0.78, 1.0, INSTANCE_CUSTOM.a);
}

void fragment() {
    vec2 centered = UV * 2.0 - 1.0;
    float radius = length(centered);
    float edge = 1.0 - smoothstep(0.72, 1.0, radius);
    float breakup = 0.5 + 0.5 * sin(centered.x * 8.0 + centered.y * 5.0 + puddle_phase);
    edge *= smoothstep(0.02, 0.30, edge + breakup * 0.08);
    float t = TIME * mix(0.0, 3.2, motion_scale);
    float ripple = sin(radius * 35.0 - t + puddle_phase) * 0.5 + 0.5;
    float fine = sin((centered.x + centered.y) * 17.0 + t * 0.63 + puddle_phase * 0.7) * 0.5 + 0.5;
    float ripple_strength = (ripple * 0.65 + fine * 0.35) * wetness;
    vec3 color = mix(vec3(0.055, 0.068, 0.072), sky_tint, 0.42 + ripple_strength * 0.12);
    ALBEDO = color;
    ROUGHNESS = mix(0.30, 0.055, wetness);
    SPECULAR = mix(0.42, 0.86, wetness);
    METALLIC = 0.0;
    NORMAL_MAP = vec3(0.5 + centered.x * ripple_strength * 0.018,
        0.5 + centered.y * ripple_strength * 0.018, 1.0);
    NORMAL_MAP_DEPTH = 0.18 * wetness;
    ALPHA = edge * mix(0.0, 0.72, smoothstep(0.24, 0.85, wetness)) * puddle_alpha;
}
