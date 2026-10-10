shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 ocean_color : source_color = vec3(0.028, 0.17, 0.23);
uniform vec3 coastal_color : source_color = vec3(0.10, 0.37, 0.40);
uniform float wave_height = 0.045;
varying vec2 ocean_uv;
varying float shore_fraction;

void vertex() {
    ocean_uv = UV;
    shore_fraction = COLOR.r;
    // Keep the source-clipped sea surface at canonical Y=0. Vertex waves on
    // independently tessellated near/far ocean edges cause tiny open seams.
    // Continuous per-fragment wave normals provide the animated surface.
}

void fragment() {
    float shore_m = shore_fraction * 40.0;
    float shore_fade = smoothstep(0.2, 5.0, shore_m);
    float first_phase = ocean_uv.x * 60.0 + ocean_uv.y * 38.0 + TIME * 1.35;
    float second_phase = ocean_uv.x * -45.0 + ocean_uv.y * 82.0 + TIME * 1.75;
    float wave_filter = 1.0 - smoothstep(0.45, 2.0,
        max(max(fwidth(first_phase), fwidth(second_phase)), 0.0));
    float first = cos(first_phase);
    float second = cos(second_phase);
    vec2 slope = vec2(first * 60.0 - second * 22.5, first * 38.0 + second * 41.0)
        * wave_height * 0.025 * shore_fade * wave_filter;
    NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-slope.x, 1.0, -slope.y)));
    float ripple = sin(first_phase) * sin(second_phase) * wave_filter;
    float depth_tint = smoothstep(0.0, 0.75, shore_fraction);
    vec3 water = mix(coastal_color, ocean_color, depth_tint);
    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
    water = mix(water, vec3(0.22, 0.37, 0.42), fresnel * 0.30);
    float surf = (1.0 - smoothstep(0.20, 1.8, shore_m))
        * smoothstep(0.10, 0.85, sin(shore_m * 3.0 + ocean_uv.x * 8.0 + ocean_uv.y * 6.0 - TIME * 1.4));
    ALBEDO = mix(water * (0.99 + ripple * 0.014), vec3(0.76, 0.82, 0.79), surf * 0.46);
    ROUGHNESS = 0.23 + ripple * 0.025;
    SPECULAR = 0.60;
    METALLIC = 0.0;
}
