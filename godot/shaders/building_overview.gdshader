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

    // At kilometre-scale viewing distances silhouette, density and lighting
    // continuity matter more than facade microdetail. Keep this material cheap
    // and stable; the registered near buildings replace it before detail is
    // expected to resolve.
    float grain = 0.965 + hash21(floor(FRAGCOORD.xy / 6.0)) * 0.035;
    ALBEDO = vec3(0.56, 0.55, 0.51) * grain;
    ROUGHNESS = 0.94;
    METALLIC = 0.0;
}