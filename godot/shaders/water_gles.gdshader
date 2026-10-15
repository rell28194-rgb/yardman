shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec3 ocean_color : source_color = vec3(0.028, 0.17, 0.23);
uniform vec3 coastal_color : source_color = vec3(0.10, 0.37, 0.40);
uniform float wave_height = 0.045;
uniform sampler2D reference_surface : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_foam : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_caustics : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D reference_normal : repeat_enable, filter_linear_mipmap;
uniform bool has_reference_surface = false;
uniform bool has_reference_foam = false;
uniform bool has_reference_caustics = false;
uniform bool has_reference_normal = false;
varying vec2 ocean_uv;
varying float shore_fraction;

void vertex() {
    ocean_uv = UV;
    shore_fraction = COLOR.r;
}

void fragment() {
    float shore_m = shore_fraction * 40.0;
    float shore_fade = smoothstep(0.2, 5.0, shore_m);
    float p1 = dot(ocean_uv, vec2(0.913, 0.408)) * 12.0 + TIME * 0.92;
    float p2 = dot(ocean_uv, vec2(-0.326, 0.946)) * 19.0 + TIME * 1.31;
    vec2 slope = vec2(0.913, 0.408) * cos(p1) * 0.040;
    slope += vec2(-0.326, 0.946) * cos(p2) * 0.023;
    if (has_reference_normal) {
        vec2 source_normal = texture(reference_normal,
            ocean_uv * 2.15 + vec2(TIME * 0.0048, -TIME * 0.0032)).rg * 2.0 - 1.0;
        slope += source_normal * 0.105 * shore_fade;
    }
    slope *= wave_height * 8.0 * shore_fade;
    NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-slope.x, 1.0, -slope.y)));

    float depth_tint = smoothstep(0.0, 0.75, shore_fraction);
    vec3 water = mix(coastal_color, ocean_color, depth_tint);
    if (has_reference_surface) {
        vec2 flow = ocean_uv * 1.75 + vec2(TIME * 0.0018, TIME * 0.0030);
        float detail = dot(texture(reference_surface, flow).rgb, vec3(0.2126, 0.7152, 0.0722));
        water *= 0.96 + detail * 0.14;
    }
    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
    water = mix(water, vec3(0.22, 0.37, 0.42), fresnel * 0.24);

    float surf = (1.0 - smoothstep(0.18, 1.8, shore_m))
        * smoothstep(0.25, 0.80, sin(shore_m * 2.4 - TIME * 0.72) * 0.5 + 0.5);
    if (has_reference_foam) {
        float foam = texture(reference_foam, ocean_uv * 5.0 + vec2(0.0, TIME * 0.008)).r;
        surf *= 0.60 + smoothstep(0.10, 0.46, foam) * 0.54;
    }
    ALBEDO = mix(water, vec3(0.76, 0.82, 0.79), surf * 0.40);
    ROUGHNESS = 0.36;
    SPECULAR = 0.44;
    METALLIC = 0.0;
}
