shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform bool unpaved = false;
uniform sampler2D reference_albedo : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_detail : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_albedo = false;
uniform bool has_reference_detail = false;
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

    // Keep several deterministic scales of variation so large junction polygons
    // do not collapse into a featureless dark slab. Derivative filtering makes
    // the pattern converge instead of sparkling at distance.
    float grain_filter = smoothstep(0.8, 1.5, max(footprint.x, footprint.y) * 24.0);
    float grain = mix(hash21(floor(UV * 24.0)), 0.5, grain_filter);
    float patch_filter = smoothstep(0.7, 1.3, max(footprint.x * 0.18, footprint.y * 0.65));
    float patch = mix(hash21(floor(UV * vec2(0.18, 0.65))), 0.5, patch_filter);
    float broad_filter = smoothstep(0.6, 1.2, max(footprint.x * 0.055, footprint.y * 0.20));
    float broad = mix(hash21(floor(UV * vec2(0.055, 0.20))), 0.5, broad_filter);

    vec3 base = unpaved ? vec3(0.34, 0.275, 0.18) : vec3(0.225, 0.232, 0.236);
    base *= 0.92 + grain * 0.08 + patch * 0.055 + broad * 0.045;
    if (has_reference_albedo) {
        vec3 reference_color = texture(reference_albedo, UV / 8.0).rgb;
        // The recovered asphalt reference has very deep texels. Preserve its
        // aggregate character without allowing daylight streets to read black.
        float reference_luma = dot(reference_color, vec3(0.2126, 0.7152, 0.0722));
        reference_color = mix(reference_color, vec3(reference_luma), 0.30);
        base = clamp(reference_color * (unpaved ? 1.10 : 2.30),
            unpaved ? vec3(0.075) : vec3(0.115),
            unpaved ? vec3(0.46) : vec3(0.43));
        if (has_reference_detail) {
            float aggregate = dot(texture(reference_detail, UV / 2.0).rgb, vec3(0.2126, 0.7152, 0.0722));
            base *= clamp(0.86 + aggregate * 1.55, 0.88, 1.24);
        }
        base *= 0.965 + patch * 0.045 + broad * 0.035;
    }

    // Give the asphalt/terrain interface a visible shoulder band using the
    // existing lateral road UV. No geometry, topology or draw-call changes.
    float edge_distance = max(0.0, width * 0.5 - abs(UV.y));
    float shoulder_width = clamp(width * 0.075, 0.46, 0.78);
    float shoulder = 1.0 - smoothstep(0.04, shoulder_width, edge_distance);
    float edge_grit = 0.88 + hash21(floor(UV * vec2(0.31, 1.85))) * 0.16;
    vec3 shoulder_color = unpaved ? vec3(0.405, 0.335, 0.225) : vec3(0.315, 0.300, 0.270);
    base = mix(base, shoulder_color * edge_grit, shoulder * (unpaved ? 0.34 : 0.58));

    // UV2 stores distance from each logical segment endpoint. Use it only as a
    // visual wear mask to break up oversized intersection plates; source road
    // geometry and registered coordinates stay untouched.
    float endpoint_distance = min(UV2.x, UV2.y);
    float junction_zone = 1.0 - smoothstep(5.0, 15.0, endpoint_distance);
    float junction_breakup = junction_zone * (0.35 + 0.65 * broad);
    vec3 junction_tone = unpaved ? vec3(0.365, 0.305, 0.215) : vec3(0.255, 0.260, 0.255);
    base = mix(base, junction_tone, junction_breakup * (unpaved ? 0.10 : 0.20));

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
        // Fade paint only inside the junction mouth. Approaches retain markings
        // closer to the intersection so road direction remains legible.
        line *= smoothstep(2.5, 7.0, endpoint_distance);
    }

    ALBEDO = mix(base, vec3(0.82, 0.815, 0.76), line * (0.80 + grain * 0.13));
    float paved_roughness = mix(0.87, 0.95, max(shoulder, junction_zone * 0.35));
    ROUGHNESS = unpaved ? 0.98 : paved_roughness;
    METALLIC = 0.0;
}
