shader_type spatial;
render_mode cull_back;

// Canonical national coordinates keep material detail fixed while floating-origin
// rendering moves the scene. The same shared noise field drives macro variation,
// UV warp and biome tint so near-field quality improves without extra texture maps.
uniform sampler2D surface_noise : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_grass : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_dry_grass : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_rock : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_rock_alternate : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_soil_detail : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_grass_normal : repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_ground = false;
uniform bool has_reference_rock = false;
uniform bool has_reference_rock_alternate = false;
uniform bool has_reference_soil_detail = false;
uniform bool has_reference_grass_normal = false;
uniform sampler2D surface_hd_lush : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_hd_dry : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_hd_soil : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_hd_rock : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_surface_hd = false;
uniform float weather_wetness : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D tunnel_portal_mask : filter_nearest, repeat_disable;
uniform bool tunnel_portal_mask_enabled = false;
uniform float terrain_tile_size = 4096.0;
uniform vec2 tile_origin = vec2(0.0);
uniform bool overview = false;
varying vec3 ground_position;
varying vec3 ground_normal;
varying vec2 national_position;
varying vec2 tile_position;

void vertex() {
    ground_position = vec3(VERTEX.x + mod(tile_origin.x, 16384.0), VERTEX.y, VERTEX.z + mod(tile_origin.y, 16384.0));
    national_position = VERTEX.xz + tile_origin;
    tile_position = VERTEX.xz;
    ground_normal = NORMAL;
}

void fragment() {
    if (tunnel_portal_mask_enabled) {
        vec2 portal_uv = clamp(tile_position / max(terrain_tile_size, 1.0), vec2(0.0), vec2(1.0));
        if (texture(tunnel_portal_mask, portal_uv).r > 0.5) {
            discard;
        }
    }

    vec3 blend = pow(abs(normalize(ground_normal)), vec3(5.0));
    blend /= max(blend.x + blend.y + blend.z, 0.0001);
    vec3 p = ground_position;
    vec3 detail = texture(surface_noise, p.yz / 4.0).rgb * blend.x
        + texture(surface_noise, p.xz / 4.0).rgb * blend.y
        + texture(surface_noise, p.xy / 4.0).rgb * blend.z;
    vec3 patch = texture(surface_noise, p.xz / 64.0).rgb;
    vec3 macro_patch = texture(surface_noise, p.xz / 512.0).rgb;
    float macro = macro_patch.r;
    float slope = 1.0 - clamp(ground_normal.y, 0.0, 1.0);
    float highland = smoothstep(350.0, 1650.0, p.y);
    float south = smoothstep(-18000.0, 18000.0, national_position.y);
    float west = 1.0 - smoothstep(-90000.0, 15000.0, national_position.x);
    float regional_dryness = 0.12 + south * 0.30 + west * south * 0.18;
    float dry = clamp(regional_dryness + (patch.g - 0.5) * 0.43 - highland * 0.17, 0.0, 0.8);
    float moisture = clamp(1.0 - dry + highland * 0.16 + (macro_patch.b - 0.5) * 0.12, 0.0, 1.0);

    vec3 lowland_wet = vec3(0.17, 0.37, 0.075);
    vec3 highland_wet = vec3(0.10, 0.31, 0.16);
    vec3 wet_grass = mix(lowland_wet, highland_wet, highland);
    vec3 dry_grass = vec3(0.50, 0.39, 0.17);
    vec3 grass = mix(wet_grass, dry_grass, dry);
    vec3 soil = mix(vec3(0.31, 0.205, 0.105), vec3(0.57, 0.385, 0.22), patch.b);
    vec3 rock = mix(vec3(0.32, 0.33, 0.27), vec3(0.66, 0.65, 0.55), detail.r);

    vec2 uv_warp = (patch.rg - vec2(0.5)) * 5.0 + (macro_patch.gb - vec2(0.5)) * 13.0;
    float family_scale = mix(0.90, 1.12, macro_patch.b);
    vec2 material_position = p.xz + uv_warp;

    if (has_surface_hd && !overview) {
        vec2 lush_uv = material_position / (5.5 * family_scale);
        vec2 dry_uv = material_position / (4.5 * mix(0.94, 1.08, patch.r));
        vec2 soil_uv = material_position / (4.0 * mix(0.90, 1.14, patch.b));
        vec2 rock_uv = material_position / (4.0 * mix(0.92, 1.10, macro_patch.g));
        vec3 lush_hd = texture(surface_hd_lush, lush_uv).rgb;
        vec3 dry_hd = texture(surface_hd_dry, dry_uv).rgb;
        grass = mix(lush_hd, dry_hd, smoothstep(0.18, 0.72, dry));
        soil = mix(texture(surface_hd_soil, soil_uv).rgb, dry_hd, dry * 0.42);
        rock = texture(surface_hd_rock, rock_uv).rgb;
    } else {
        if (has_reference_ground) {
            vec3 warped = vec3(p.x + uv_warp.x, p.y, p.z + uv_warp.y);
            vec3 wet = texture(reference_grass, warped.yz / 8.0).rgb * blend.x
                + texture(reference_grass, warped.xz / 8.0).rgb * blend.y
                + texture(reference_grass, warped.xy / 8.0).rgb * blend.z;
            vec3 dry_texture = texture(reference_dry_grass, warped.yz / 8.0).rgb * blend.x
                + texture(reference_dry_grass, warped.xz / 8.0).rgb * blend.y
                + texture(reference_dry_grass, warped.xy / 8.0).rgb * blend.z;
            grass = mix(wet, dry_texture, dry);
        }
        if (has_reference_rock) {
            vec3 warped = vec3(p.x + uv_warp.x, p.y, p.z + uv_warp.y);
            rock = texture(reference_rock, warped.yz / 8.0).rgb * blend.x
                + texture(reference_rock, warped.xz / 8.0).rgb * blend.y
                + texture(reference_rock, warped.xy / 8.0).rgb * blend.z;
            if (has_reference_rock_alternate && !overview) {
                // Use one dominant-axis lookup instead of another full triplanar
                // set: the alternate recovered rock breaks family repetition at
                // a bounded single texture-sample cost on private builds.
                vec2 alternate_uv = warped.xz / (10.0 * family_scale);
                if (blend.x > blend.y && blend.x > blend.z) {
                    alternate_uv = warped.yz / (10.0 * family_scale);
                } else if (blend.z > blend.y) {
                    alternate_uv = warped.xy / (10.0 * family_scale);
                }
                vec3 alternate_rock = texture(reference_rock_alternate, alternate_uv).rgb * 1.08;
                float alternate_mix = smoothstep(0.36, 0.76, macro_patch.r) * 0.62;
                rock = mix(rock, alternate_rock, alternate_mix);
            }
            rock *= 1.10;
        }
    }

    if (has_reference_soil_detail && !overview) {
        // Direct survival-island woodsground source is restricted to the soil
        // family. It contributes one top-projected sample only; the existing
        // bare-soil mask still decides where it can become visible, so it gains
        // no terrain, biome, land-cover or placement authority.
        vec3 recovered_soil = texture(reference_soil_detail,
            material_position / (9.0 * family_scale)).rgb;
        float recovered_luma = dot(recovered_soil, vec3(0.2126, 0.7152, 0.0722));
        recovered_soil *= mix(0.88, 1.08, recovered_luma);
        recovered_soil *= mix(vec3(0.94, 1.00, 0.94), vec3(1.06, 0.96, 0.86), dry * 0.35);
        soil = mix(soil, recovered_soil, 0.58);
    }

    grass *= mix(0.80, 1.12, patch.r) * mix(0.90, 1.08, macro);
    float grass_luma = dot(grass, vec3(0.2126, 0.7152, 0.0722));
    grass = clamp(mix(vec3(grass_luma), grass, 1.06) * mix(0.92, 1.02, moisture), vec3(0.0), vec3(0.95));
    grass *= mix(vec3(0.96, 1.04, 0.94), vec3(1.05, 0.96, 0.86), dry);
    soil *= mix(0.87, 1.10, patch.b) * mix(vec3(0.93, 0.98, 0.94), vec3(1.08, 0.96, 0.86), dry);
    rock *= mix(0.92, 1.10, detail.r);

    float pale_rock = smoothstep(0.62, 0.88, macro_patch.g) * smoothstep(0.16, 0.58, slope) * (1.0 - highland * 0.34);
    rock = mix(rock, rock * vec3(1.16, 1.15, 1.08), pale_rock * 0.46);

    float bare = smoothstep(0.66, 0.85, patch.g) * (0.16 + dry * 0.65);
    float rocky = smoothstep(0.22, 0.59, slope) * mix(0.72, 1.0, patch.b);
    vec3 color = mix(mix(grass, soil, bare), rock, rocky);
    float grain = overview ? 1.0 : mix(0.90, 1.08, detail.g);
    float wetness = clamp(weather_wetness, 0.0, 1.0) * (overview ? 0.35 : 1.0);
    ALBEDO = color * grain * mix(1.0, 0.73, wetness);
    ROUGHNESS = mix(mix(0.96, 0.87, rocky), 0.38, wetness);
    SPECULAR = mix(0.14, 0.48, wetness);
    if (!overview) {
        vec2 normal_xy = (detail.rg - vec2(0.5)) * (0.16 + rocky * 0.13);
        if (has_reference_grass_normal) {
            vec2 source_normal = texture(reference_grass_normal, material_position / (8.0 * family_scale)).rg - vec2(0.5);
            float grass_normal_weight = (1.0 - smoothstep(0.20, 0.62, rocky)) * (1.0 - bare * 0.70) * 0.72;
            normal_xy = mix(normal_xy, source_normal * 0.82, grass_normal_weight);
        }
        NORMAL_MAP = vec3(normal_xy + vec2(0.5), 1.0);
        NORMAL_MAP_DEPTH = mix(0.24, 0.34, wetness);
    }
}
