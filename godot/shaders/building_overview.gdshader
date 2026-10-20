shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float near_distance = 1200.0;
uniform float far_distance = 5600.0;
varying float camera_distance;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    camera_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
    // Opaque dithered handoff avoids sorted transparency and lets the detailed
    // registered buildings replace these proxies without a hard pop.
    float near_cut = 1.0 - smoothstep(near_distance, near_distance + 260.0, camera_distance);
    float far_cut = smoothstep(far_distance - 700.0, far_distance, camera_distance);
    if (hash21(FRAGCOORD.xy) < max(near_cut, far_cut)) {
        discard;
    }

    vec3 base = mix(vec3(0.61, 0.59, 0.53), vec3(0.48, 0.50, 0.48), clamp(COLOR.a, 0.0, 1.0));
    base *= 0.94 + hash21(floor(WORLD_MATRIX[3].xz / 24.0)) * 0.10;
    ALBEDO = base;
    ROUGHNESS = 0.94;
    METALLIC = 0.0;
}