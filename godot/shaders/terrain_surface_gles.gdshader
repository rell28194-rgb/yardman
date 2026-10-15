shader_type spatial;
render_mode cull_back;

// GLES-safe terrain path. Registered geometry remains identical; this variant
// keeps a fixed sample budget while still accepting direct recovered detail.
uniform sampler2D surface_noise : repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_grass : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_dry_grass : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_rock : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_grass_normal : repeat_enable, filter_linear_mipmap;
uniform bool has_reference_ground = false;
uniform bool has_reference_rock = false;
uniform bool has_reference_grass_normal = false;
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
    vec3 p = ground_position;
    vec3 patch = texture(surface_noise, p.xz / 64.0).rgb;
    float slope = 1.0 - clamp(normalize(ground_normal).y, 0.0, 1.0);
    float highland = smoothstep(350.0, 1650.0, p.y);
    float south = smoothstep(-18000.0, 18000.0, national_position.y);
    float west = 1.0 - smoothstep(-90000.0, 15000.0, national_position.x);
    float dry = clamp(0.12 + south * 0.30 + west * south * 0.18 + (patch.g - 0.5) * 0.34 - highland * 0.14, 0.0, 0.8);

    vec3 grass = mix(vec3(0.24, 0.34, 0.105), vec3(0.48, 0.40, 0.19), dry);
    if (has_reference_ground) {
        vec3 wet = texture(reference_grass, p.xz / 8.0).rgb;
        vec3 dry_texture = texture(reference_dry_grass, p.xz / 8.0).rgb;
        grass = mix(wet, dry_texture, dry);
    }
    grass *= mix(0.80, 1.18, patch.r);
    vec3 soil = mix(vec3(0.30, 0.22, 0.12), vec3(0.53, 0.38, 0.24), patch.b);
    vec3 rock = vec3(0.42, 0.41, 0.35);
    if (has_reference_rock && slope > 0.22) {
        rock = texture(reference_rock, p.xz / 8.0).rgb * 1.06;
    }
    float bare = smoothstep(0.69, 0.88, patch.g) * (0.14 + dry * 0.58);
    float rocky = smoothstep(0.28, 0.64, slope);
    ALBEDO = mix(mix(grass, soil, bare), rock, rocky);
    ROUGHNESS = mix(0.97, 0.90, rocky);
    SPECULAR = 0.11;
    if (!overview && has_reference_grass_normal) {
        vec2 grass_n = texture(reference_grass_normal, p.xz / 8.0).rg * 2.0 - 1.0;
        float grass_weight = (1.0 - rocky) * (1.0 - bare) * (1.0 - dry * 0.22);
        NORMAL_MAP = vec3(grass_n * 0.15 * clamp(grass_weight, 0.0, 1.0) + vec2(0.5), 1.0);
        NORMAL_MAP_DEPTH = 0.22;
    }
}
