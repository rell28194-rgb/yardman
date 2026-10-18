shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform bool unpaved = false;
uniform sampler2D reference_albedo : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_detail : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_albedo = false;
uniform bool has_reference_detail = false;
uniform float visibility_distance = 2600.0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float standing_water : hint_range(0.0, 1.0) = 0.0;
varying float camera_distance;
varying float road_up_alignment;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    camera_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
    road_up_alignment = clamp(abs(NORMAL.y), 0.0, 1.0);
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
    float aggregate_micro = 0.5;
    vec3 base = unpaved ? vec3(0.34, 0.275, 0.18) : vec3(0.205, 0.217, 0.225);
    base *= 0.91 + grain * 0.12 + patch * 0.06;
    if (has_reference_albedo) {
        vec3 reference_color = texture(reference_albedo, UV / 8.0).rgb;
        base = clamp(reference_color * (unpaved ? 1.10 : 2.30), vec3(0.055), vec3(0.46));
        if (has_reference_detail) {
            aggregate_micro = dot(texture(reference_detail, UV / 2.0).rgb, vec3(0.2126, 0.7152, 0.0722));
            base *= clamp(0.80 + aggregate_micro * 1.90, 0.82, 1.30);
        }
    }
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
    float surface_wetness = unpaved ? wetness * 0.48 : wetness;
    float puddle_flatness = smoothstep(0.965, 0.998, road_up_alignment);
    float puddle_mask = unpaved ? 0.0 : smoothstep(0.58, 0.86, patch) * standing_water * puddle_flatness;
    vec3 surface = mix(base, vec3(0.82, 0.815, 0.76), line * (0.78 + grain * 0.15));
    surface *= mix(1.0, 0.70, surface_wetness * 0.82);
    surface *= mix(1.0, 0.94, puddle_mask * 0.45);
    ALBEDO = surface;

    // High quality asphalt should not read as one uniform rough plastic sheet.
    // Reuse the detail/grain values already sampled for albedo so this adds no
    // extra texture fetch. Wetness progressively suppresses the dry aggregate
    // breakup, while road paint remains slightly smoother than the asphalt.
    float micro_roughness = mix(grain, aggregate_micro, has_reference_detail ? 0.74 : 0.0);
    float dry_road_roughness = mix(0.82, 0.94, clamp(micro_roughness, 0.0, 1.0));
    ROUGHNESS = unpaved ? mix(0.98, 0.84, surface_wetness) : mix(dry_road_roughness, 0.34, surface_wetness);
    ROUGHNESS = mix(ROUGHNESS, 0.56, line * (1.0 - surface_wetness * 0.55));
    ROUGHNESS = mix(ROUGHNESS, 0.10, puddle_mask * 0.90);
    float dry_specular = mix(0.20, 0.28, clamp(micro_roughness, 0.0, 1.0));
    SPECULAR = mix(dry_specular, 0.64, surface_wetness);
    SPECULAR = mix(SPECULAR, 0.82, puddle_mask * 0.72);
    METALLIC = 0.0;
}
