shader_type spatial;
render_mode cull_back;

uniform bool roof_surface = false;
uniform float visibility_distance = 800.0;
uniform float weather_wetness : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D reference_plaster : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_brick : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_concrete : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_timber : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_timber_01 : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_timber_03 : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_timber_04 : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stone : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stone_alternate : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stone_alternate_02 : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_roof : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_tiles : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stucco_natural : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stucco_red : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_stucco_yellow : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_plaster = false;
uniform bool has_reference_brick = false;
uniform bool has_reference_concrete = false;
uniform bool has_reference_timber = false;
uniform bool has_reference_timber_01 = false;
uniform bool has_reference_timber_03 = false;
uniform bool has_reference_timber_04 = false;
uniform bool has_reference_stone = false;
uniform bool has_reference_stone_alternate = false;
uniform bool has_reference_stone_alternate_02 = false;
uniform bool has_reference_roof = false;
uniform bool has_reference_tiles = false;
uniform bool has_reference_stucco_natural = false;
uniform bool has_reference_stucco_red = false;
uniform bool has_reference_stucco_yellow = false;
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
    SPECULAR = 0.14;
    if (roof_surface) {
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
        // Natural stucco is restrained microdetail for the two painted families.
        // It adds one sample only there; the existing palette id still owns paint.
        float painted_stucco_micro = 1.0;
        if (COLOR.a < 0.3 && has_reference_stucco_natural) {
            vec3 natural_stucco = texture(reference_stucco_natural, UV / 3.8).rgb;
            float natural_luma = dot(natural_stucco, vec3(0.2126, 0.7152, 0.0722));
            painted_stucco_micro = mix(0.88, 1.12, clamp(natural_luma, 0.0, 1.0));
        }
        if (COLOR.a < 0.1 && has_reference_stucco_red) {
            surface = texture(reference_stucco_red, UV / 3.4).rgb * 1.12
                * mix(vec3(0.94), COLOR.rgb * 1.18, 0.10) * painted_stucco_micro;
            ROUGHNESS = 0.91;
        }
        if (COLOR.a > 0.1 && COLOR.a < 0.3 && has_reference_stucco_yellow) {
            surface = texture(reference_stucco_yellow, UV / 3.5).rgb * 1.10
                * mix(vec3(0.95), COLOR.rgb * 1.15, 0.10) * painted_stucco_micro;
            ROUGHNESS = 0.91;
        }
        if (COLOR.a > 0.3 && COLOR.a < 0.5 && has_reference_brick) {
            surface = texture(reference_brick, UV / 1.28).rgb * 1.35;
        }
        if (COLOR.a > 0.5 && COLOR.a < 0.7 && has_reference_concrete) {
            surface = texture(reference_concrete, UV / 2.9).rgb * 1.38
                * mix(vec3(0.91), COLOR.rgb * 1.42, 0.22);
            ROUGHNESS = 0.94;
        }
        if (COLOR.a > 0.7 && COLOR.a < 0.9 && has_reference_stone) {
            // One alternate sample only on stone-family wall fragments. The
            // selector chooses exactly one source family before sampling it;
            // this increases variation without stacking stone texture reads.
            float stone_selector = grain(floor(vec2(UV.x / 12.0, UV.y / 5.5)) + vec2(41.0, 17.0));
            if (stone_selector > 0.68 && has_reference_stone_alternate_02) {
                surface = texture(reference_stone_alternate_02, UV / 3.9).rgb * 1.36;
            } else if (stone_selector > 0.34 && has_reference_stone_alternate) {
                surface = texture(reference_stone_alternate, UV / 4.2).rgb * 1.34;
            } else {
                surface = texture(reference_stone, UV / 3.5).rgb * 1.4;
            }
            ROUGHNESS = 0.93;
        }
        if (COLOR.a > 0.9 && has_reference_timber) {
            // Existing timber geometry and palette id stay authoritative. One
            // deterministic family is selected per broad UV block, so each
            // fragment samples one timber source rather than blending four.
            float timber_selector = grain(floor(vec2(UV.x / 11.0, UV.y / 5.0)) + vec2(13.0, 73.0));
            if (timber_selector > 0.75 && has_reference_timber_04) {
                surface = texture(reference_timber_04, UV / 2.9).rgb * 1.18;
            } else if (timber_selector > 0.50 && has_reference_timber_03) {
                surface = texture(reference_timber_03, UV / 2.85).rgb * 1.20;
            } else if (timber_selector > 0.25 && has_reference_timber_01) {
                surface = texture(reference_timber_01, UV / 3.0).rgb * 1.16;
            } else {
                surface = texture(reference_timber, UV / 2.8).rgb * 1.2;
            }
            ROUGHNESS = 0.90;
        }

        vec2 module = fract(vec2(UV.x / 3.2, -UV.y / 3.15));
        float window_x = step(0.29, module.x) * step(module.x, 0.70);
        float window_y = step(0.28, module.y) * step(module.y, 0.63);
        vec2 cell = floor(vec2(UV.x / 3.2, -UV.y / 3.15));
        float replaced = step(-999.0, UV2.x) * step(UV2.x, cell.x)
            * step(cell.x, UV2.x + 2.0) * (1.0 - step(0.5, abs(cell.y - UV2.y))) * step(view_distance, 100.0);
        float window = window_x * window_y * (1.0 - replaced);

        float frame_outer_x = step(0.255, module.x) * step(module.x, 0.735);
        float frame_outer_y = step(0.235, module.y) * step(module.y, 0.675);
        float frame = frame_outer_x * frame_outer_y * (1.0 - window) * (1.0 - replaced);
        vec3 frame_tint = mix(vec3(0.70, 0.68, 0.61), vec3(0.90, 0.88, 0.80), clamp(COLOR.r, 0.0, 1.0));
        surface = mix(surface, frame_tint, frame * 0.72);

        vec3 glass = vec3(0.13, 0.22, 0.25);
        surface = mix(surface, glass, window);
        ROUGHNESS = mix(ROUGHNESS, 0.30, window);
        float sill = window_x * step(0.64, module.y) * step(module.y, 0.67) * (1.0 - replaced);
        surface = mix(surface, vec3(0.68, 0.65, 0.58), sill);

        float ground_band = 1.0 - smoothstep(0.10, 0.72, abs(UV.y));
        float dirt = 0.80 + 0.12 * grain(floor(vec2(UV.x * 1.7, UV.y * 7.0)));
        surface *= mix(1.0, dirt, ground_band * 0.42);
    }

    // Weather uses the same shared building material rather than adding wet
    // overlays or extra draw calls.
    float wetness = clamp(weather_wetness, 0.0, 1.0);
    float wet_darkening = roof_surface ? 0.72 : 0.82;
    surface *= mix(1.0, wet_darkening, wetness);
    float wet_roughness = roof_surface ? 0.32 : min(ROUGHNESS, 0.46);
    ROUGHNESS = mix(ROUGHNESS, wet_roughness, wetness);
    SPECULAR = mix(SPECULAR, roof_surface ? 0.48 : 0.36, wetness);
    ALBEDO = surface;
}
