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
    float shore_fade = smoothstep(0.0, 0.30, COLOR.r);
    float first = sin(UV.x * 2.2 + UV.y * 1.1 + TIME * 0.85);
    float second = sin(UV.x * -1.3 + UV.y * 2.9 + TIME * 1.25);
    VERTEX.y += (first + second * 0.4) * wave_height * shore_fade;
    float dx = cos(UV.x * 2.2 + UV.y * 1.1 + TIME * 0.85) * 2.2
        + cos(UV.x * -1.3 + UV.y * 2.9 + TIME * 1.25) * -0.52;
    float dz = cos(UV.x * 2.2 + UV.y * 1.1 + TIME * 0.85) * 1.1
        + cos(UV.x * -1.3 + UV.y * 2.9 + TIME * 1.25) * 1.16;
    NORMAL = normalize(vec3(-dx * wave_height * 0.025 * shore_fade, 1.0,
        -dz * wave_height * 0.025 * shore_fade));
}

void fragment() {
    float ripple = sin(ocean_uv.x * 14.0 + ocean_uv.y * 8.0 + TIME * 1.9)
        * sin(ocean_uv.x * -9.0 + ocean_uv.y * 17.0 + TIME * 1.1);
    float depth_tint = smoothstep(0.0, 0.75, shore_fraction);
    vec3 water = mix(coastal_color, ocean_color, depth_tint);
    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
    water = mix(water, vec3(0.22, 0.37, 0.42), fresnel * 0.30);
    float surf = (1.0 - smoothstep(0.005, 0.035, shore_fraction))
        * smoothstep(0.10, 0.85, sin(ocean_uv.x * 10.0 + ocean_uv.y * 6.0 + TIME * 1.4));
    ALBEDO = mix(water * (0.98 + ripple * 0.025), vec3(0.72, 0.79, 0.75), surf * 0.34);
    ROUGHNESS = 0.28 + ripple * 0.025;
    SPECULAR = 0.60;
    METALLIC = 0.0;
}
