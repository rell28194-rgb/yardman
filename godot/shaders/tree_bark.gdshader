shader_type spatial;
render_mode cull_disabled;
varying vec3 local_position;
varying vec3 vertex_tint;
void vertex() {
    local_position = VERTEX;
    vertex_tint = COLOR.rgb;
}
void fragment() {
    float rings = sin(local_position.y * 30.0) * 0.025;
    float speckle = fract(sin(dot(floor(local_position.xy * 41.0), vec2(12.71, 78.21))) * 43758.5453);
    ALBEDO = vertex_tint * (0.91 + speckle * 0.13 + rings);
    ROUGHNESS = 0.97;
    SPECULAR = 0.07;
}
