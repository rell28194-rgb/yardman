shader_type spatial;
render_mode cull_disabled;

uniform vec3 sand_color : source_color = vec3(0.56, 0.49, 0.34);

float grain(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
    float broad = grain(floor(UV * 0.65));
    float fine = grain(floor(UV * 28.0));
    ALBEDO = sand_color * (0.88 + broad * 0.14 + fine * 0.07);
    ROUGHNESS = 0.96;
    SPECULAR = 0.14;
}
