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
    // This is horizontal coastline adjacency, not bathymetry. It keeps the
    // registered shore readable without pretending the 40 m distance channel
    // contains measured underwater depth.
    float shoreline_tint = 1.0 - smoothstep(1.0, 18.0, shore_m);
    water = mix(water, vec3(0.10, 0.43, 0.42), shoreline_tint * 0.10);
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
    float edge_surf = (1.0 - smoothstep(0.16, 1.25, shore_m))
        * smoothstep(0.28, 0.84, sin(foam_phase) * 0.5 + 0.5);
    // The secondary wash is one soft coastal envelope broken in two world-UV
    // directions, avoiding the parallel contour-line ribbons produced by a
    // shore-distance-only phase.
    float wash_envelope = smoothstep(0.65, 1.8, shore_m)
        * (1.0 - smoothstep(3.4, 5.4, shore_m));
    float along_a = sin(dot(ocean_uv, vec2(8.7, 17.3)) + TIME * 0.41) * 0.5 + 0.5;
    float along_b = sin(dot(ocean_uv, vec2(-15.1, 6.4)) - TIME * 0.29) * 0.5 + 0.5;
    float breakup = smoothstep(0.30, 0.76, along_a * 0.64 + along_b * 0.36);
    float wash_phase = sin(shore_m * 0.72
        + dot(ocean_uv, vec2(0.70, -0.40)) * 2.1
        + swell.x * 1.8 - TIME * 0.46) * 0.5 + 0.5;
    float shoreline_wash = wash_envelope * breakup * smoothstep(0.32, 0.76, wash_phase);
    float surf = max(edge_surf * 0.45, shoreline_wash * 0.38);
    if (has_reference_foam) {
        float foam = texture(reference_foam,
            ocean_uv * 6.1 + vec2(0.0, TIME * 0.011)).r;
        surf *= 0.60 + smoothstep(0.10, 0.46, foam) * 0.52;
    }
    float foam_response = clamp(surf * 0.92 + (1.0 - shore_fade) * 0.04, 0.0, 1.0);
    ALBEDO = mix(water, vec3(0.78, 0.85, 0.82), surf * 0.36);
    ROUGHNESS = mix(0.30, 0.47, foam_response);
    SPECULAR = mix(0.54, 0.30, foam_response);
    METALLIC = 0.0;
}
