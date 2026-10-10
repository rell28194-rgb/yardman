shader_type spatial;
render_mode cull_disabled;
uniform float wind_strength = 0.22;
uniform vec3 tint : source_color = vec3(0.33, 0.46, 0.16);
varying vec3 leaf_color;

void vertex() {
    // Translation is only a phase. A rebase changes no persistent placement.
    float phase = INSTANCE_CUSTOM.x * 6.283185;
    float motion = sin(TIME * 1.4 + phase + VERTEX.y * 0.61)
        + sin(TIME * 2.0 + phase * 0.73) * 0.27;
    VERTEX.x += motion * wind_strength * COLOR.a;
    VERTEX.z += cos(TIME * 1.13 + phase + VERTEX.y) * wind_strength * COLOR.a * 0.4;
    leaf_color = COLOR.rgb * mix(vec3(0.91, 0.92, 0.81), vec3(1.12, 1.08, 1.03), INSTANCE_CUSTOM.y);
    leaf_color *= mix(vec3(1.0), vec3(1.23, 1.08, 0.79), clamp(INSTANCE_CUSTOM.z, 0.0, 1.0));
}

void fragment() {
    ALBEDO = leaf_color * tint;
    ROUGHNESS = 0.86;
    SPECULAR = 0.18;
    BACKLIGHT = leaf_color * tint * 0.17;
}
