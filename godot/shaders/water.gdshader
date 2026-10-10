shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec3 ocean_color : source_color = vec3(0.028, 0.17, 0.23);
uniform vec3 coastal_color : source_color = vec3(0.10, 0.37, 0.40);
uniform float wave_height = 0.045;
uniform sampler2D reference_surface : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_foam : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_caustics : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_surface = false;
uniform bool has_reference_foam = false;
uniform bool has_reference_caustics = false;
varying vec2 ocean_uv;
varying float shore_fraction;

void vertex() {
    ocean_uv = UV;
    shore_fraction = COLOR.r;
    // Geometry stays at canonical sea level. Independent streamed ocean pieces
    // therefore share exact edges; all movement below is normal-only.
}

void fragment() {
    float shore_m = shore_fraction * 40.0;
    float shore_fade = smoothstep(0.2, 5.0, shore_m);

    // Four unrelated directional bands avoid the cross-hatched/checker pattern
    // produced by multiplying two periodic waves. UV is world-registered, so
    // these phases remain continuous across every streamed coast tile.
    float p1 = dot(ocean_uv, vec2(0.913, 0.408)) * 18.7 + TIME * 1.08;
    float p2 = dot(ocean_uv, vec2(-0.326, 0.946)) * 31.9 + TIME * 1.57 + 1.31;
    float p3 = dot(ocean_uv, vec2(0.672, -0.741)) * 47.3 + TIME * 2.03 + 2.17;
    float p4 = dot(ocean_uv, vec2(-0.801, -0.598)) * 72.1 + TIME * 2.61 + 0.73;

    float f1 = 1.0 - smoothstep(0.55, 2.2, fwidth(p1));
    float f2 = 1.0 - smoothstep(0.55, 2.2, fwidth(p2));
    float f3 = 1.0 - smoothstep(0.55, 2.2, fwidth(p3));
    float f4 = 1.0 - smoothstep(0.55, 2.2, fwidth(p4));

    vec2 slope = vec2(0.0);
    slope += vec2(0.913, 0.408) * cos(p1) * 0.105 * f1;
    slope += vec2(-0.326, 0.946) * cos(p2) * 0.061 * f2;
    slope += vec2(0.672, -0.741) * cos(p3) * 0.033 * f3;
    slope += vec2(-0.801, -0.598) * cos(p4) * 0.016 * f4;
    slope *= wave_height * 8.5 * shore_fade;
    NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-slope.x, 1.0, -slope.y)));

    float ripple = (sin(p1) * 0.44 * f1 + sin(p2) * 0.29 * f2
        + sin(p3) * 0.18 * f3 + sin(p4) * 0.09 * f4);
    float broad = sin(dot(ocean_uv, vec2(0.173, 0.985)) * 5.7 + TIME * 0.22) * 0.5 + 0.5;
    float depth_tint = smoothstep(0.0, 0.75, shore_fraction);
    vec3 water = mix(coastal_color, ocean_color, depth_tint);
    water *= 0.985 + broad * 0.025;
    if (has_reference_surface) {
        // Read the source water image as luminance detail rather than applying
        // its baked black/teal colours over Jamaica's registered coastline.
        vec2 flow = ocean_uv * 2.1 + vec2(TIME * 0.0021, TIME * 0.0013);
        float detail = dot(texture(reference_surface, flow).rgb, vec3(0.2126, 0.7152, 0.0722));
        water *= 0.975 + detail * 0.075;
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

    // Narrow moving shore foam uses independent phases rather than a repeating
    // 2-D product, so shallow water reads as coastline instead of a texture grid.
    float foam_phase = shore_m * 2.6 + p1 * 0.12 + p2 * 0.07 - TIME * 0.78;
    float surf = (1.0 - smoothstep(0.20, 1.9, shore_m))
        * smoothstep(0.22, 0.82, sin(foam_phase) * 0.5 + 0.5);
    if (has_reference_foam) {
        float foam = dot(texture(reference_foam,
            ocean_uv * 6.1 + vec2(TIME * 0.010, TIME * 0.006)).rgb,
            vec3(0.2126, 0.7152, 0.0722));
        surf *= 0.56 + smoothstep(0.10, 0.46, foam) * 0.64;
    }
    ALBEDO = mix(water * (0.995 + ripple * 0.012), vec3(0.76, 0.82, 0.79), surf * 0.43);
    ROUGHNESS = clamp(0.235 + ripple * 0.018, 0.18, 0.30);
    SPECULAR = 0.60;
    METALLIC = 0.0;
}
