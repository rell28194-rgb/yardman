shader_type spatial;
render_mode cull_disabled;

uniform bool roof_surface = false;
uniform float visibility_distance = 800.0;
varying float view_distance;

float grain(vec2 point) {
    return fract(sin(dot(point, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
    view_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
    if (view_distance > visibility_distance + 120.0) {
        discard;
    }
    vec3 surface = COLOR.rgb;
    float fine_grain = grain(floor(UV * 38.0));
    surface *= 0.95 + fine_grain * 0.08;
    ROUGHNESS = 0.88;
    if (roof_surface) {
        float seam = smoothstep(0.02, 0.08, abs(fract(UV.x * 1.6) - 0.5));
        surface *= 0.78 + 0.22 * seam;
        ROUGHNESS = 0.68;
        METALLIC = 0.12;
    } else {
        // Original generic facade: real footprint and source/inferred height,
        // with declared inferred windows rather than borrowed game textures.
        vec2 module = fract(vec2(UV.x / 3.2, -UV.y / 3.15));
        float window_x = step(0.29, module.x) * step(module.x, 0.70);
        float window_y = step(0.28, module.y) * step(module.y, 0.63);
        float window = window_x * window_y;
        vec3 glass = vec3(0.13, 0.22, 0.25);
        surface = mix(surface, glass, window);
        ROUGHNESS = mix(0.88, 0.30, window);
        float sill = window_x * step(0.64, module.y) * step(module.y, 0.67);
        surface = mix(surface, vec3(0.68, 0.65, 0.58), sill);
    }
    ALBEDO = surface;
}
