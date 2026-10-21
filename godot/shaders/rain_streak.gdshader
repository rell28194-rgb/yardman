shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform vec3 rain_tint : source_color = vec3(0.72, 0.82, 0.90);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_direction = vec2(0.18, -0.06);
varying float drop_alpha;

void vertex() {
    float phase = INSTANCE_CUSTOM.r;
    float speed = mix(14.0, 23.0, INSTANCE_CUSTOM.g);
    float travel = mod(TIME * speed + phase * 22.0, 22.0);
    drop_alpha = INSTANCE_CUSTOM.a;
    VERTEX.y -= travel;
    VERTEX.x += wind_direction.x * travel;
    VERTEX.z += wind_direction.y * travel;
}

void fragment() {
    float edge = 1.0 - abs(UV.x * 2.0 - 1.0);
    float head = smoothstep(0.0, 0.18, UV.y);
    float tail = 1.0 - smoothstep(0.70, 1.0, UV.y);
    float alpha = smoothstep(0.08, 0.72, edge) * head * tail;
    ALBEDO = rain_tint;
    ALPHA = alpha * mix(0.20, 0.68, intensity) * mix(0.68, 1.0, drop_alpha);
}
