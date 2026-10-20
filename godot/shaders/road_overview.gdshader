shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float near_distance = 1900.0;
uniform float far_distance = 14500.0;
varying float camera_distance;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    camera_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
    Z_CLIP_SCALE = 0.99992;
}

void fragment() {
    // Cross-fade against the detailed road streamer without transparency or
    // sorting. The arterial HLOD is absent close to the camera and dissolves
    // at the far horizon instead of ending as a hard 2.6 km ring.
    float near_cut = 1.0 - smoothstep(near_distance, near_distance + 550.0, camera_distance);
    float far_cut = smoothstep(far_distance - 1600.0, far_distance, camera_distance);
    if (hash21(FRAGCOORD.xy) < max(near_cut, far_cut)) {
        discard;
    }

    float width = max(COLOR.r * 64.0, 1.0);
    float hierarchy = clamp(COLOR.g * 16.0 / 8.0, 0.0, 1.0);
    vec3 asphalt = vec3(0.245, 0.250, 0.248);
    vec3 arterial = vec3(0.285, 0.282, 0.260);
    ALBEDO = mix(asphalt, arterial, hierarchy * 0.28) * (0.97 + min(width, 10.0) * 0.002);
    ROUGHNESS = 0.96;
    METALLIC = 0.0;
}