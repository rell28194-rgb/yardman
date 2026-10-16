shader_type spatial;
render_mode cull_back;

uniform vec3 sand_color : source_color = vec3(0.70, 0.65, 0.50);
uniform sampler2D reference_sand : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool has_reference_sand = false;

float grain(vec2 p) {
    p = fract(p * vec2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

float smooth_grain(vec2 p) {
    vec2 cell = floor(p);
    vec2 blend = fract(p);
    blend = blend * blend * (3.0 - 2.0 * blend);
    return mix(mix(grain(cell), grain(cell + vec2(1.0, 0.0)), blend.x),
        mix(grain(cell + vec2(0.0, 1.0)), grain(cell + vec2(1.0)), blend.x), blend.y);
}

void fragment() {
    // Continuous variation replaces the conspicuous eight-metre square tiles.
    float broad = smooth_grain(UV * 0.55);
    float detail = smooth_grain(UV * 5.5);
    float fine = grain(floor(UV * 40.0));
    float filter_amount = smoothstep(0.45, 1.5, max(fwidth(UV.x * 40.0), fwidth(UV.y * 40.0)));
    fine = mix(fine, 0.5, filter_amount);
    vec3 sand = sand_color;
    if (has_reference_sand) {
        // The supplied sand image repeats every three real metres; the same
        // world UV survives tile streaming and a floating-origin shift.
        sand = clamp(texture(reference_sand, UV).rgb * 1.28, vec3(0.15), vec3(0.86));
    }
    ALBEDO = sand * (0.91 + broad * 0.10 + detail * 0.045 + fine * 0.035);
    ROUGHNESS = 0.96;
    SPECULAR = 0.14;
}
