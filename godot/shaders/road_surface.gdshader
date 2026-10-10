shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform bool unpaved = false;
uniform float visibility_distance = 2600.0;
varying float camera_distance;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    camera_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
    // A minute depth-only scale supplements the physical overlay on grazing
    // views; road lighting and canonical/physics geometry are unchanged.
    Z_CLIP_SCALE = 0.99997;
}

void fragment() {
    // A dithered opaque range keeps roads on resident fine terrain. Transparent
    // blending would reintroduce sorting glitches at intersecting road strips.
    float range_fade = smoothstep(visibility_distance * 0.85, visibility_distance, camera_distance);
    if (hash21(FRAGCOORD.xy) < range_fade) {
        discard;
    }
    float width = max(COLOR.r * 64.0, 1.0);
    int paint = int(round(COLOR.g * 2.0));
    int lanes = clamp(int(round(COLOR.b * 8.0)), 1, 8);
    vec2 footprint = fwidth(UV);
    float grain_filter = smoothstep(0.8, 1.5, max(footprint.x, footprint.y) * 24.0);
    float grain = mix(hash21(floor(UV * 24.0)), 0.5, grain_filter);
    float patch_filter = smoothstep(0.7, 1.3, max(footprint.x * 0.18, footprint.y * 0.65));
    float patch = mix(hash21(floor(UV * vec2(0.18, 0.65))), 0.5, patch_filter);
    vec3 base = unpaved ? vec3(0.34, 0.275, 0.18) : vec3(0.205, 0.217, 0.225);
    base *= 0.91 + grain * 0.12 + patch * 0.06;
    float edge_distance = max(0.0, width * 0.5 - abs(UV.y));
    float shoulder = 1.0 - smoothstep(0.0, 0.32, edge_distance);
    base = mix(base, unpaved ? vec3(0.40, 0.33, 0.22) : vec3(0.27, 0.265, 0.245), shoulder * 0.23);
    float dash = 1.0 - step(3.2, mod(UV.x, 8.5));
    dash = mix(dash, 3.2 / 8.5, smoothstep(1.5, 4.0, footprint.x));
    float line_softness = max(footprint.y * 0.6, 0.015);
    float line = 0.0;
    if (!unpaved && paint > 0) {
        if (paint == 1) {
            line = (1.0 - smoothstep(max(0.0, 0.0625 - line_softness), 0.0625 + line_softness, abs(UV.y))) * dash;
        } else {
            float lane_width = width / float(lanes);
            for (int lane = 1; lane < 8; lane++) {
                if (lane < lanes) {
                    float offset = -width * 0.5 + lane_width * float(lane);
                    line = max(line, (1.0 - smoothstep(max(0.0, 0.0625 - line_softness), 0.0625 + line_softness, abs(UV.y - offset))) * dash);
                }
            }
        }
        // Logical-edge junctions are left unpainted, avoiding crossed dashes
        // at intersections. Markings are explicitly inferred, never surveyed.
        line *= smoothstep(4.0, 9.0, min(UV2.x, UV2.y));
    }
    ALBEDO = mix(base, vec3(0.82, 0.815, 0.76), line * (0.78 + grain * 0.15));
    ROUGHNESS = unpaved ? 0.98 : 0.88;
    METALLIC = 0.0;
}
