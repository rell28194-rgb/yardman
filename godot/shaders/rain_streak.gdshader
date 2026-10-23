shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform vec3 rain_tint : source_color = vec3(0.72, 0.82, 0.90);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_direction = vec2(0.18, -0.06);
varying float drop_alpha;
varying float drop_tier;

void vertex() {
    float phase = INSTANCE_CUSTOM.r;
    float tier = clamp(INSTANCE_CUSTOM.b, 0.0, 1.0);
    // Tropico's recovered rain behavior uses roughly 20-30 m/s across its
    // near/middle/far emitters. Yardman keeps one batched mesh and encodes the
    // visual tier per instance instead of allocating three rain draw batches.
    float speed = mix(20.0, 30.0, INSTANCE_CUSTOM.g) * mix(0.94, 1.08, tier);
    float travel_span = mix(22.0, 30.0, tier);
    float travel = mod(TIME * speed + phase * travel_span, travel_span);
    drop_alpha = INSTANCE_CUSTOM.a;
    drop_tier = tier;
    VERTEX.y -= travel;
    VERTEX.x += wind_direction.x * travel;
    VERTEX.z += wind_direction.y * travel;
}

void fragment() {
    float edge = 1.0 - abs(UV.x * 2.0 - 1.0);
    float head = smoothstep(0.0, 0.18, UV.y);
    float tail = 1.0 - smoothstep(0.70, 1.0, UV.y);
    float alpha = smoothstep(0.08, 0.72, edge) * head * tail;
    vec3 tier_tint = mix(rain_tint, vec3(0.79, 0.84, 0.91), drop_tier * 0.42);
    ALBEDO = tier_tint;
    ALPHA = alpha * mix(0.20, 0.68, intensity)
        * mix(0.68, 1.0, drop_alpha) * mix(1.0, 0.64, drop_tier);
}
