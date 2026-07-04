shader_type canvas_item;
// Animated water for the floating-islands world. Two looks selected by `mode`:
//   mode 0 = pond: slow drifting ripples with a soft moving specular glint.
//   mode 1 = waterfall: vertical scrolling stripes with a bright foam lip at the top
//            and a fade toward the bottom (water spilling off an island edge).
// Driven by `water_phase` (0..1), fed from the SYNCHRONIZED GameClock by
// client/client_world.gd (exactly like the sky), so every peer in a lobby sees the
// same flow with no extra network traffic. Cosmetic only; never touches the sim.
//
// gl_compatibility-safe (matches world/sky.gdshader's rules): only arithmetic +
// fract/sin/mix/smoothstep, a constant-bound loop, no fwidth/textureLod.
// (TAU/PI are Godot shader built-ins — do NOT redeclare them.)

uniform int   mode = 0;
uniform float water_phase = 0.0;                       // 0..1 synced flow phase
uniform vec4  tint : source_color = vec4(0.25, 0.55, 0.85, 0.85);

// Per-vertex world-position phase offset so neighbouring features don't pulse in
// lockstep (the WaterLayer nodes sit at the origin, so VERTEX == world px).
varying float inst;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	inst = (VERTEX.x * 0.6 + VERTEX.y * 0.4) * 0.02;
}

void fragment() {
	float wp = water_phase + inst;
	if (mode == 1) {
		// Waterfall: stripes scroll downward; foam at the lip, thinning toward the base.
		float stripes = fract(UV.y * 6.0 - wp * 8.0);
		float band = smoothstep(0.35, 0.5, stripes) * smoothstep(0.85, 0.6, stripes);
		vec3 col = mix(tint.rgb * 0.7, vec3(1.0), band * 0.6);
		float foam = smoothstep(0.14, 0.0, UV.y);          // bright lip at the top
		col = mix(col, vec3(1.0), foam);
		float fade = smoothstep(1.0, 0.55, UV.y);          // fade out toward the bottom
		float a = tint.a * (0.6 + 0.4 * band) * fade;
		COLOR = vec4(col, a);
	} else {
		// Pond: two drifting noise fields make gentle ripples + a moving glint.
		vec2 p = UV * 5.0;
		float n = vnoise(p + vec2(wp, wp * 0.6)) + vnoise(p * 1.7 - vec2(wp * 0.8, 0.0));
		n *= 0.5;
		float glint = smoothstep(0.75, 0.95, n + 0.15 * sin(wp * TAU + UV.x * 8.0));
		vec3 col = mix(tint.rgb * 0.85, tint.rgb * 1.15, n);
		col = mix(col, vec3(1.0), glint * 0.5);
		COLOR = vec4(col, tint.a);
	}
}
