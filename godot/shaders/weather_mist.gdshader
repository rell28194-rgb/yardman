shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform vec3 mist_tint : source_color = vec3(0.70, 0.75, 0.78);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
varying float mist_alpha;

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
    float phase = INSTANCE_CUSTOM.r;
    float drift = mix(0.22, 0.62, INSTANCE_CUSTOM.g);
    float travel = mod(TIME * drift + phase * 12.0, 12.0) - 6.0;
    VERTEX.x += travel * mix(-0.24, 0.24, INSTANCE_CUSTOM.b);
    VERTEX.z += travel * 0.11;
    mist_alpha = INSTANCE_CUSTOM.a;
}

void fragment() {
    vec2 centered = UV * 2.0 - 1.0;
    float radial = 1.0 - smoothstep(0.30, 1.0, length(centered));
    float breakup = mix(0.72, 1.0, hash21(floor(UV * 9.0) + floor(TIME * 0.18)));
    ALBEDO = mist_tint;
    ALPHA = radial * breakup * mist_alpha * mix(0.0, 0.19, intensity);
}
