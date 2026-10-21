shader_type spatial;
render_mode blend_mix, depth_draw_alpha_prepass, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.08, 0.42, 0.46, 0.72);
uniform vec4 deep_color : source_color = vec4(0.025, 0.19, 0.27, 0.82);
uniform vec4 foam_color : source_color = vec4(0.76, 0.91, 0.90, 0.72);
uniform float flow_speed : hint_range(0.0, 4.0) = 0.65;
uniform float ripple_scale : hint_range(0.2, 8.0) = 2.2;
uniform float opacity : hint_range(0.0, 1.0) = 0.78;

void fragment() {
    float along = UV.y * ripple_scale;
    float across = UV.x;
    float t = TIME * flow_speed;
    float wave_a = sin((along - t) * 6.2831853 + across * 2.4);
    float wave_b = sin((along * 0.47 - t * 0.73) * 6.2831853 - across * 5.1);
    float wave = wave_a * 0.62 + wave_b * 0.38;
    float edge = smoothstep(0.68, 0.98, abs(across * 2.0 - 1.0));
    float foam = smoothstep(0.45, 0.95, wave) * edge * 0.58;
    float depth_mix = clamp(0.34 + edge * 0.28 - wave * 0.06, 0.0, 1.0);
    vec3 water = mix(shallow_color.rgb, deep_color.rgb, depth_mix);
    ALBEDO = mix(water, foam_color.rgb, foam);
    ROUGHNESS = mix(0.18, 0.34, edge);
    METALLIC = 0.0;
    SPECULAR = 0.72;
    ALPHA = clamp(opacity + foam * 0.12 - edge * 0.07, 0.0, 1.0);
    NORMAL_MAP = normalize(vec3(wave_a * 0.12, wave_b * 0.10, 1.0)) * 0.5 + 0.5;
    NORMAL_MAP_DEPTH = 0.32;
}
