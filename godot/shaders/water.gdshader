shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec3 ocean_color : source_color = vec3(0.028, 0.17, 0.23);
uniform vec3 coastal_color : source_color = vec3(0.10, 0.37, 0.40);
uniform float wave_height = 0.045;
uniform sampler2D reference_surface : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_foam : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_caustics : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_normal : repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_surface = false;
uniform bool has_reference_foam = false;
uniform bool has_reference_caustics = false;
uniform bool has_reference_normal = false;
varying vec2 ocean_uv;
varying float shore_fraction;

float wave_hash(vec2 p) {
    vec3 h = fract(vec3(p.xyx) * 0.1031);
    h += dot(h, h.yzx + 33.33);
    return fract((h.x + h.y) * h.z);
}

vec3 wave_noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    vec2 du = 6.0 * f * (1.0 - f);
    float a = wave_hash(cell);
    float b = wave_hash(cell + vec2(1.0, 0.0));
    float c = wave_hash(cell + vec2(0.0, 1.0));
    float d = wave_hash(cell + vec2(1.0, 1.0));
    float cross_term = a - b - c + d;
    return vec3(a + (b - a) * u.x + (c - a) * u.y + cross_term * u.x * u.y,
        du * (vec2(b - a, c - a) + cross_term * u.yx));
}

void vertex() {
    ocean_uv = UV;
    shore_fraction = COLOR.r;
}

void fragment() {
    float shore_m = shore_fraction * 40.0;
    float shore_fade = smoothstep(0.2, 5.0, shore_m);
    vec3 swell = wave_noise(ocean_uv * 1.7 + vec2(TIME * 0.023, -TIME * 0.017));
    vec2 wind = vec2(0.913, 0.408);
    float p1 = dot(ocean_uv, wind) * 18.7 + TIME * 1.08 + swell.x * 7.0;
    float p2 = dot(ocean_uv, vec2(-0.326, 0.946)) * 31.9 + TIME * 1.57 + swell.x * 4.1;
    float f1 = 1.0 - smoothstep(0.55, 2.2, fwidth(p1));
    float f2 = 1.0 - smoothstep(0.55, 2.2, fwidth(p2));
    vec3 chop = wave_noise(ocean_uv * 9.3 + vec2(-TIME * 0.079, TIME * 0.046));
    vec3 fine = wave_noise(ocean_uv * 23.7 + vec2(TIME * 0.13, TIME * 0.081));
    float chop_filter = 1.0 - smoothstep(0.25, 0.85, length(fwidth(ocean_uv * 9.3)));
    float fine_filter = 1.0 - smoothstep(0.25, 0.85, length(fwidth(ocean_uv * 23.7)));
    vec2 slope = wind * cos(p1) * 0.038 * f1;
    slope += vec2(-0.326, 0.946) * cos(p2) * 0.025 * f2;
    slope += chop.yz * 0.18 * chop_filter + fine.yz * 0.071 * fine_filter;
    if (has_reference_normal) {
        // Direct Beta2 source path: the recovered uCaptain WaterBump is a
        // 512x512 ETC1 texture with its original ten-level mip chain preserved.
        // Two differently moving reads avoid making the source tiling obvious.
        vec2 source_a = texture(reference_normal,
            ocean_uv * 2.35 + vec2(TIME * 0.0061, -TIME * 0.0040)).rg * 2.0 - 1.0;
        vec2 source_b = texture(reference_normal,
            ocean_uv.yx * 3.65 + vec2(-TIME * 0.0035, TIME * 0.0052)).rg * 2.0 - 1.0;
        slope += (source_a * 0.105 + source_b * 0.070) * shore_fade;
    }
    slope *= wave_height * 8.5 * shore_fade;
    NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-slope.x, 1.0, -slope.y)));

    float depth_tint = smoothstep(0.0, 0.75, shore_fraction);
    vec3 water = mix(coastal_color, ocean_color, depth_tint);
    water *= 0.97 + swell.x * 0.06;
    if (has_reference_surface) {
        vec2 flow = ocean_uv * 2.1 + vec2(0.0, TIME * 0.0031);
        float detail = dot(texture(reference_surface, flow).rgb, vec3(0.2126, 0.7152, 0.0722));
        water *= 0.96 + detail * 0.18;
    }
    if (has_reference_caustics) {
        float caustic = dot(texture(reference_caustics,
            ocean_uv * 3.7 + vec2(TIME * 0.004, -TIME * 0.002)).rgb,
            vec3(0.2126, 0.7152, 0.0722));
        water += vec3(0.014, 0.021, 0.018) * caustic
            * (1.0 - smoothstep(2.0, 12.0, shore_m));
    }
    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
    water = mix(water, vec3(0.22, 0.37, 0.42), fresnel * 0.30);

    float foam_phase = shore_m * 2.6 + swell.x * 3.0 - TIME * 0.78;
    float surf = (1.0 - smoothstep(0.20, 1.9, shore_m))
        * smoothstep(0.22, 0.82, sin(foam_phase) * 0.5 + 0.5);
    if (has_reference_foam) {
        float foam = texture(reference_foam,
            ocean_uv * 6.1 + vec2(0.0, TIME * 0.011)).r;
        surf *= 0.56 + smoothstep(0.10, 0.46, foam) * 0.64;
    }
    ALBEDO = mix(water, vec3(0.76, 0.82, 0.79), surf * 0.43);
    ROUGHNESS = mix(0.31, 0.37, 1.0 - fine_filter);
    SPECULAR = 0.52;
    METALLIC = 0.0;
}
