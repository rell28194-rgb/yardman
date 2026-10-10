shader_type spatial;
render_mode cull_disabled;

// Original procedural surface. Canonical origins deliberately replace
// MODEL_MATRIX translation: shifting the renderer never slides the texture.
uniform sampler2D surface_noise : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec2 tile_origin = vec2(0.0);
uniform bool overview = false;
varying vec3 ground_position;
varying vec3 ground_normal;
varying vec2 national_position;

void vertex() {
    ground_position = vec3(VERTEX.x + mod(tile_origin.x, 16384.0), VERTEX.y, VERTEX.z + mod(tile_origin.y, 16384.0));
    national_position = VERTEX.xz + tile_origin;
    ground_normal = NORMAL;
}

void fragment() {
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
    grass *= mix(0.73, 1.29, patch.r) * mix(0.84, 1.14, macro);
    vec3 soil = mix(vec3(0.30, 0.22, 0.12), vec3(0.53, 0.38, 0.24), patch.b);
    vec3 rock = mix(vec3(0.34, 0.34, 0.28), vec3(0.61, 0.60, 0.49), detail.r);
    float bare = smoothstep(0.66, 0.85, patch.g) * (0.16 + dry * 0.65);
    float rocky = smoothstep(0.22, 0.59, slope) * mix(0.72, 1.0, patch.b);
    vec3 color = mix(mix(grass, soil, bare), rock, rocky);
    float grain = overview ? 1.0 : mix(0.85, 1.14, detail.g);
    ALBEDO = color * grain;
    ROUGHNESS = mix(0.96, 0.87, rocky);
    SPECULAR = 0.14;
    // A subtle texture normal adds surface detail without changing geography.
    if (!overview) {
        vec2 normal_xy = (detail.rg - vec2(0.5)) * (0.16 + rocky * 0.13);
        NORMAL_MAP = vec3(normal_xy + vec2(0.5), 1.0);
        NORMAL_MAP_DEPTH = 0.24;
    }
}
