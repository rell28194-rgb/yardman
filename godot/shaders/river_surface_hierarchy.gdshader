shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

// V2 hydrology vertex COLOR contract:
//   r = normalized compiled ribbon width
//   g = normalized geometric grade
//   b = rapidness proxy derived from width + grade
//   a = metadata-present marker
// This is a rendering hierarchy. It does not change hydrology source truth.
uniform vec4 stream_color : source_color = vec4(0.075, 0.48, 0.53, 0.72);
uniform vec4 river_color : source_color = vec4(0.035, 0.30, 0.34, 0.79);
uniform vec4 broad_color : source_color = vec4(0.075, 0.235, 0.225, 0.84);
uniform vec4 foam_color : source_color = vec4(0.79, 0.93, 0.91, 0.78);
uniform float base_flow_speed : hint_range(0.0, 4.0) = 0.62;
uniform float opacity : hint_range(0.0, 1.0) = 0.80;

void fragment() {
    float width_factor = clamp(COLOR.r, 0.0, 1.0);
    float grade_factor = clamp(COLOR.g, 0.0, 1.0);
    float rapid = clamp(COLOR.b, 0.0, 1.0);

    float flow = base_flow_speed * mix(1.32, 0.72, width_factor) * mix(0.88, 1.70, grade_factor);
    float ripple_scale = mix(3.7, 1.35, width_factor) * mix(0.92, 1.18, grade_factor);
    float along = UV.y * ripple_scale;
    float across = UV.x;
    float t = TIME * flow;
    float wave_a = sin((along - t) * 6.2831853 + across * 2.7);
    float wave_b = sin((along * 0.43 - t * 0.69) * 6.2831853 - across * 5.4);
    float wave = wave_a * 0.60 + wave_b * 0.40;
    float edge = smoothstep(0.66, 0.98, abs(across * 2.0 - 1.0));

    vec3 narrow = stream_color.rgb;
    vec3 medium = river_color.rgb;
    vec3 broad = broad_color.rgb;
    vec3 water = mix(narrow, medium, smoothstep(0.12, 0.58, width_factor));
    water = mix(water, broad, smoothstep(0.54, 0.95, width_factor));
    // Faster/narrower water reads cleaner and brighter; broad slow water is
    // slightly more muted/turbid without asserting sediment measurements.
    water *= mix(vec3(1.08, 1.09, 1.05), vec3(0.91, 0.96, 0.90), width_factor);
    water = mix(water, water * vec3(0.91, 1.03, 1.05), grade_factor * 0.36);

    float edge_foam = smoothstep(0.40, 0.94, wave) * edge * mix(0.22, 0.48, rapid);
    float rapid_foam = smoothstep(0.58, 0.96, wave) * rapid * (1.0 - edge * 0.55) * 0.64;
    float foam = clamp(edge_foam + rapid_foam, 0.0, 0.82);
    ALBEDO = mix(water, foam_color.rgb, foam);
    ROUGHNESS = mix(mix(0.19, 0.31, width_factor), 0.38, edge);
    METALLIC = 0.0;
    SPECULAR = mix(0.78, 0.62, width_factor);
    ALPHA = clamp(opacity + foam * 0.13 - edge * 0.055 - rapid * 0.025, 0.0, 1.0);
    NORMAL_MAP = normalize(vec3(wave_a * mix(0.17, 0.08, width_factor), wave_b * mix(0.14, 0.07, width_factor), 1.0)) * 0.5 + 0.5;
    NORMAL_MAP_DEPTH = mix(0.38, 0.24, width_factor) + rapid * 0.08;
}
