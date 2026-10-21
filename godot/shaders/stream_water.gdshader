shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 stream_color : source_color = vec3(0.055, 0.255, 0.285);
uniform vec3 shallow_color : source_color = vec3(0.13, 0.43, 0.39);
uniform float flow_speed = 0.42;
uniform sampler2D reference_surface : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_foam : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D reference_caustics : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_surface = false;
uniform bool has_reference_foam = false;
uniform bool has_reference_caustics = false;

float hash21(vec2 p) {
    vec3 h = fract(vec3(p.xyx) * 0.1031);
    h += dot(h, h.yzx + 33.33);
    return fract((h.x + h.y) * h.z);
}

float noise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
    float edge = smoothstep(0.58, 0.98, abs(UV.x * 2.0 - 1.0));
    float speed = flow_speed * mix(0.72, 1.35, clamp(COLOR.g, 0.0, 1.0));
    vec2 flow_uv = vec2(UV.x * 2.4, UV.y - TIME * speed);
    float coarse = noise2(flow_uv * vec2(4.0, 1.7));
    float fine = noise2(flow_uv * vec2(11.0, 4.7) + vec2(TIME * 0.07, 0.0));
    float texture_detail = 0.5;
    if (has_reference_surface) {
        texture_detail = dot(texture(reference_surface, flow_uv * vec2(1.7, 0.62)).rgb,
            vec3(0.2126, 0.7152, 0.0722));
    }
    vec3 water = mix(stream_color, shallow_color, edge * 0.66);
    water *= 0.91 + coarse * 0.09 + fine * 0.035 + texture_detail * 0.07;
    if (has_reference_caustics) {
        float caustic = dot(texture(reference_caustics, flow_uv * vec2(2.5, 0.75)).rgb,
            vec3(0.2126, 0.7152, 0.0722));
        water += vec3(0.018, 0.025, 0.018) * caustic * (1.0 - edge);
    }
    float foam = edge * smoothstep(0.50, 0.86, coarse + fine * 0.22);
    if (has_reference_foam) {
        foam *= 0.55 + texture(reference_foam, flow_uv * vec2(3.2, 0.8)).r * 0.75;
    }
    ALBEDO = mix(water, vec3(0.72, 0.82, 0.76), clamp(foam, 0.0, 0.52));
    ROUGHNESS = mix(0.28, 0.44, edge);
    SPECULAR = 0.48;
    METALLIC = 0.0;
}
