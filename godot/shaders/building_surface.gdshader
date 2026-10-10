shader_type spatial;
render_mode cull_back;

uniform bool roof_surface = false;
uniform float visibility_distance = 800.0;
uniform sampler2D reference_plaster : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_brick : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_timber : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stone : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_roof : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_tiles : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_plaster = false;
uniform bool has_reference_brick = false;
uniform bool has_reference_timber = false;
uniform bool has_reference_stone = false;
uniform bool has_reference_roof = false;
uniform bool has_reference_tiles = false;
varying float view_distance;

float grain(vec2 point) {
    return fract(sin(dot(point, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
    view_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
    if (view_distance > visibility_distance + 120.0) {
        discard;
    }
    vec3 surface = COLOR.rgb;
    float fine_grain = grain(floor(UV * 38.0));
    fine_grain = mix(fine_grain, 0.5, smoothstep(0.4, 1.4, max(fwidth(UV.x * 38.0), fwidth(UV.y * 38.0))));
    surface *= 0.95 + fine_grain * 0.08;
    ROUGHNESS = 0.88;
    if (roof_surface) {
        // Source images are plain roof surfaces, not a facade atlas stretched
        // over an entire roof. Roof UVs retain a real-metre repeat frequency.
        if (has_reference_roof) {
            surface *= texture(reference_roof, UV / 3.0).rgb * 1.9;
        }
        if (COLOR.a > 0.5 && has_reference_tiles) {
            surface = texture(reference_tiles, UV / 2.6).rgb * 1.45
                * mix(vec3(0.88), COLOR.rgb * 1.75, 0.3);
        }
        float seam = smoothstep(0.02, 0.08, abs(fract(UV.x * 1.6) - 0.5));
        surface *= 0.78 + 0.22 * seam;
        ROUGHNESS = 0.68;
        METALLIC = 0.12;
    } else {
        if (has_reference_plaster) {
            surface *= texture(reference_plaster, UV / 3.6).rgb * 1.85;
        }
        if (COLOR.a > 0.3 && COLOR.a < 0.5 && has_reference_brick) {
            // The decoded source has sixteen courses per image: a 1.28m
            // repeat gives ordinary eight-centimetre courses.
            surface = texture(reference_brick, UV / 1.28).rgb * 1.35;
        }
        if (COLOR.a > 0.7 && COLOR.a < 0.9 && has_reference_stone) {
            surface = texture(reference_stone, UV / 3.5).rgb * 1.4;
        }
        if (COLOR.a > 0.9 && has_reference_timber) {
            surface = texture(reference_timber, UV / 2.8).rgb * 1.2;
        }
        // Window layout remains explicitly inferred, independent of OSM
        // footprints and source heights; art does not alter geography.
        vec2 module = fract(vec2(UV.x / 3.2, -UV.y / 3.15));
        float window_x = step(0.29, module.x) * step(module.x, 0.70);
        float window_y = step(0.28, module.y) * step(module.y, 0.63);
        float window = window_x * window_y;
        vec3 glass = vec3(0.13, 0.22, 0.25);
        surface = mix(surface, glass, window);
        ROUGHNESS = mix(0.88, 0.30, window);
        float sill = window_x * step(0.64, module.y) * step(module.y, 0.67);
        surface = mix(surface, vec3(0.68, 0.65, 0.58), sill);
    }
    ALBEDO = surface;
}
