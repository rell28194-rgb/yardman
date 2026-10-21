shader_type spatial;
render_mode cull_back;

// Original procedural surface. Canonical origins deliberately replace
// MODEL_MATRIX translation: shifting the renderer never slides the texture.
uniform sampler2D surface_noise : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_grass : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_dry_grass : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_rock : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_ground = false;
uniform bool has_reference_rock = false;
// Optional post-install Surface HD materials. These use the same canonical
// coordinate field and never alter registered terrain geometry or collision.
uniform sampler2D surface_hd_lush : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_hd_dry : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_hd_soil : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_hd_rock : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_surface_hd = false;
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
    // Only true negative-layer tunnel portals receive a mask. The mountain
    // remains intact over the tunnel interior; this removes just the opening
    // where the profiled road deck passes beneath the terrain surface.
    if (tunnel_portal_mask_enabled) {
        vec2 portal_uv = clamp(tile_position / max(terrain_tile_size, 1.0), vec2(0.0), vec2(1.0));
        if (texture(tunnel_portal_mask, portal_uv).r > 0.5) {
            discard;
        }
    }

    vec3 blend = pow(abs(normalize(ground_normal)), vec3(5.0));
    blend /= max(blend.x + blend.y + blend.z, 0.0001);
    vec3 p = ground_position;
    // Powers of two divide the canonical precision wrap exactly, including
    // neighbouring tiles on a 16 km boundary.
    vec3 detail = texture(surface_noise, p.yz / 4.0).rgb * blend.x
        + texture(surface_noise, p.xz / 4.0).rgb * blend.y
        + texture(surface_noise, p.xy / 4.0).rgb * blend.z;
    vec3 patch = texture(surface_noise, p.xz / 64.0).rgb;
    float macro = texture(surface_noise, p.xz / 512.0).r;
    float slope = 1.0 - clamp(ground_normal.y, 0.0, 1.0);
    float highland = smoothstep(350.0, 1650.0, p.y);
    float south = smoothstep(-18000.0, 18000.0, national_position.y);
    float west = 1.0 - smoothstep(-90000.0, 15000.0, national_position.x);
    float regional_dryness = 0.12 + south * 0.30 + west * south * 0.18;
    float dry = clamp(regional_dryness + (patch.g - 0.5) * 0.43 - highland * 0.17, 0.0, 0.8);
    vec3 wet_grass = vec3(0.24, 0.34, 0.105);
    vec3 dry_grass = vec3(0.48, 0.40, 0.19);
    vec3 grass = mix(wet_grass, dry_grass, dry);
    vec3 soil = mix(vec3(0.30, 0.22, 0.12), vec3(0.53, 0.38, 0.24), patch.b);
    vec3 rock = mix(vec3(0.34, 0.34, 0.28), vec3(0.61, 0.60, 0.49), detail.r);

    if (has_surface_hd && !overview) {
        // One planar sample per surface family is substantially cheaper than
        // full triplanar PBR stacks on Android. The national terrain grid is
        // smooth enough that this is a better quality/performance trade here.
        vec2 lush_uv = p.xz / 5.5;
        vec2 dry_uv = p.xz / 4.5;
        vec2 soil_uv = p.xz / 4.0;
        vec2 rock_uv = p.xz / 4.0;
        vec3 lush_hd = texture(surface_hd_lush, lush_uv).rgb;
        vec3 dry_hd = texture(surface_hd_dry, dry_uv).rgb;
        grass = mix(lush_hd, dry_hd, smoothstep(0.18, 0.72, dry));
        soil = mix(texture(surface_hd_soil, soil_uv).rgb, dry_hd, dry * 0.42);
        rock = texture(surface_hd_rock, rock_uv).rgb;
    } else {
        if (has_reference_ground) {
            vec3 wet = texture(reference_grass, p.yz / 8.0).rgb * blend.x
                + texture(reference_grass, p.xz / 8.0).rgb * blend.y
                + texture(reference_grass, p.xy / 8.0).rgb * blend.z;
            vec3 dry_texture = texture(reference_dry_grass, p.yz / 8.0).rgb * blend.x
                + texture(reference_dry_grass, p.xz / 8.0).rgb * blend.y
                + texture(reference_dry_grass, p.xy / 8.0).rgb * blend.z;
            grass = mix(wet, dry_texture, dry);
        }
        if (has_reference_rock) {
            rock = texture(reference_rock, p.yz / 8.0).rgb * blend.x
                + texture(reference_rock, p.xz / 8.0).rgb * blend.y
                + texture(reference_rock, p.xy / 8.0).rgb * blend.z;
            rock *= 1.12;
        }
    }

    // Keep the recovered/downloaded variation inside a lighting-safe range so
    // the Android sun pass cannot turn lowland grass fluorescent.
    grass *= mix(0.78, 1.12, patch.r) * mix(0.88, 1.08, macro);
    float grass_luma = dot(grass, vec3(0.2126, 0.7152, 0.0722));
    grass = mix(vec3(grass_luma), grass, 0.82) * 0.88;
    soil *= mix(0.88, 1.08, patch.b);
    rock *= mix(0.92, 1.10, detail.r);

    float bare = smoothstep(0.66, 0.85, patch.g) * (0.16 + dry * 0.65);
    float rocky = smoothstep(0.22, 0.59, slope) * mix(0.72, 1.0, patch.b);
    vec3 color = mix(mix(grass, soil, bare), rock, rocky);
    float grain = overview ? 1.0 : mix(0.90, 1.08, detail.g);
    ALBEDO = color * grain;
    ROUGHNESS = mix(0.96, 0.87, rocky);
    SPECULAR = 0.14;
    // Keep the existing procedural micro-normal: it costs one small shared
    // texture instead of six extra normal maps and remains stable while driving.
    if (!overview) {
        vec2 normal_xy = (detail.rg - vec2(0.5)) * (0.16 + rocky * 0.13);
        NORMAL_MAP = vec3(normal_xy + vec2(0.5), 1.0);
        NORMAL_MAP_DEPTH = 0.24;
    }
}
