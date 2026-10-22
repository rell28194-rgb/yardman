shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D reference_gravel : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_gravel = false;
uniform vec4 shallow_color : source_color = vec4(0.10, 0.44, 0.45, 0.72);
uniform vec4 foam_color : source_color = vec4(0.77, 0.90, 0.86, 0.68);
uniform float opacity : hint_range(0.0, 1.0) = 0.70;
uniform float flow_speed : hint_range(0.0, 4.0) = 0.78;

void fragment() {
    float along = UV.y;
    float across = UV.x;
    float t = TIME * flow_speed;
    float wave_a = sin((along * 4.6 - t) * 6.2831853 + across * 2.8);
    float wave_b = sin((along * 2.1 - t * 0.63) * 6.2831853 - across * 5.4);
    float wave = wave_a * 0.66 + wave_b * 0.34;

    // Fade the overlay into the already-continuous river ribbon at both road
    // edges. This is a shallow surface skin, not a replacement waterway.
    float end_fade = smoothstep(0.00, 0.18, along) * smoothstep(0.00, 0.18, 1.0 - along);
    float side_fade = smoothstep(0.00, 0.08, across) * smoothstep(0.00, 0.08, 1.0 - across);
    float coverage = end_fade * side_fade;

    vec3 bed = vec3(0.30, 0.27, 0.20);
    if (has_reference_gravel) {
        bed = texture(reference_gravel, vec2(across * 2.8, along * 6.5)).rgb;
        float bed_luma = dot(bed, vec3(0.2126, 0.7152, 0.0722));
        bed = mix(vec3(bed_luma), bed, 0.72);
    }
    float unpaved = clamp(COLOR.r, 0.0, 1.0);
    float bed_visibility = mix(0.24, 0.38, unpaved) + wave * 0.025;
    vec3 water = mix(shallow_color.rgb, bed, clamp(bed_visibility, 0.18, 0.42));
    float edge = smoothstep(0.70, 0.98, abs(across * 2.0 - 1.0));
    float foam = smoothstep(0.54, 0.95, wave) * edge * 0.35;
    ALBEDO = mix(water, foam_color.rgb, foam);
    ROUGHNESS = mix(0.22, 0.38, edge);
    SPECULAR = 0.64;
    METALLIC = 0.0;
    ALPHA = clamp(opacity * coverage + foam * 0.08, 0.0, 0.78);
    NORMAL_MAP = normalize(vec3(wave_a * 0.10, wave_b * 0.08, 1.0)) * 0.5 + 0.5;
    NORMAL_MAP_DEPTH = 0.25;
}
