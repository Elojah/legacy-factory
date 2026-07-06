shader_type canvas_item;
// Procedural sky for the floating-islands world. A vertical gradient, an arcing sun and
// moon, drifting fbm clouds, and a night star field — all keyed off a single
// `time_of_day` (0..1, 0 = dawn) so the whole sky animates over one day. The client
// feeds `time_of_day` from the SYNCHRONIZED GameClock tick, so every peer in a lobby
// sees the same sky (see client/client_world.gd _update_sky). Cosmetic only.
//
// Kept gl_compatibility-safe: only arithmetic, fract/sin/mix/smoothstep/pow and a
// constant-bound loop — no derivatives (fwidth) or textureLod.
// (TAU/PI are Godot shader built-ins — do NOT redeclare them.)

uniform float time_of_day = 0.35;   // 0..1 day phase (0 = dawn, .25 noon, .5 dusk, .75 midnight)
uniform float cloud_phase = 0.0;    // synced horizontal cloud scroll
uniform vec2  cam_offset = vec2(0.0); // camera world px, for subtle cloud parallax
uniform vec2  resolution = vec2(960.0, 540.0); // viewport px, for aspect correction

// Cyclic triangular weight: 1 at center `c`, falling to 0 a quarter-day away, wrapping.
// The four phase weights always sum to 1, so this is a smooth cyclic 4-key blend.
float wphase(float t, float c) {
	float d = abs(fract(t - c + 0.5) - 0.5);
	return max(0.0, 1.0 - d * 4.0);
}

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

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 5; i++) {
		v += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	float aspect = resolution.x / max(1.0, resolution.y);
	float t = time_of_day;

	// --- gradient: cyclic blend of dawn/day/dusk/night zenith+horizon keyframes ---
	float wDawn  = wphase(t, 0.0);
	float wDay   = wphase(t, 0.25);
	float wDusk  = wphase(t, 0.5);
	float wNight = wphase(t, 0.75);
	vec3 zenith = vec3(0.30, 0.32, 0.62) * wDawn + vec3(0.20, 0.48, 0.95) * wDay
		+ vec3(0.24, 0.18, 0.50) * wDusk + vec3(0.02, 0.03, 0.10) * wNight;
	vec3 horizon = vec3(1.00, 0.58, 0.35) * wDawn + vec3(0.66, 0.88, 1.00) * wDay
		+ vec3(1.00, 0.42, 0.30) * wDusk + vec3(0.08, 0.11, 0.24) * wNight;
	vec3 col = mix(zenith, horizon, smoothstep(0.0, 1.0, UV.y));
	// Low haze band brightening toward the horizon line.
	col = mix(col, mix(horizon, vec3(1.0), 0.25), smoothstep(0.55, 0.95, UV.y) * 0.22);

	// Celestial elevation: +1 at noon, 0 at the horizon, -1 at midnight.
	float h = sin(t * TAU);
	float sun_up = smoothstep(-0.05, 0.12, h);
	float moon_up = smoothstep(-0.05, 0.12, -h);
	float daylight = clamp(h * 0.5 + 0.5, 0.0, 1.0);
	float horizon_y = 0.72;
	float arc = 0.56;

	// --- stars (night, upper sky) ---
	vec2 sg = floor(UV * vec2(aspect, 1.0) * 260.0);
	float star = step(0.990, hash(sg));
	float tw = 0.6 + 0.4 * sin(hash(sg + 3.1) * TAU + cloud_phase * 40.0);
	col += vec3(star * tw) * (1.0 - daylight) * smoothstep(0.68, 0.15, UV.y);

	// --- sun (rises east/left at dawn, sets west/right at dusk) ---
	float sun_x = t * 2.0;
	float sun_y = horizon_y - h * arc;
	float sd = length((UV - vec2(sun_x, sun_y)) * vec2(aspect, 1.0));
	float sun_disk = smoothstep(0.05, 0.035, sd);
	float sun_glow = pow(max(0.0, 1.0 - sd / 0.7), 3.0);
	vec3 sun_col = mix(vec3(1.0, 0.6, 0.3), vec3(1.0, 0.96, 0.8), smoothstep(0.0, 0.5, h));
	col += sun_col * (sun_disk + sun_glow * 0.75) * sun_up;

	// --- moon (opposite arc; a soft crescent) ---
	float moon_x = fract(t + 0.5) * 2.0;
	float moon_y = horizon_y + h * arc;
	float md = length((UV - vec2(moon_x, moon_y)) * vec2(aspect, 1.0));
	float moon_disk = smoothstep(0.038, 0.028, md);
	float moon_shadow = smoothstep(0.036, 0.026, length((UV - vec2(moon_x + 0.012, moon_y - 0.006)) * vec2(aspect, 1.0)));
	moon_disk = max(0.0, moon_disk - moon_shadow * 0.85);
	float moon_glow = pow(max(0.0, 1.0 - md / 0.3), 3.0);
	col += vec3(0.85, 0.88, 1.0) * (moon_disk + moon_glow * 0.25) * moon_up;

	// --- clouds (domain-warped fbm, scrolled + parallaxed, tinted by time of day) ---
	vec2 cp = vec2(UV.x * aspect, UV.y) * 2.6 + vec2(cloud_phase, 0.0) + cam_offset * 0.00003;
	float clouds = fbm(cp + vec2(fbm(cp * 0.5), 0.0));
	float cover = smoothstep(0.52, 0.80, clouds) * smoothstep(0.92, 0.30, UV.y);
	vec3 cloud_col = mix(vec3(0.16, 0.18, 0.28), vec3(1.0, 1.0, 1.0), daylight);
	cloud_col = mix(cloud_col, horizon, (1.0 - smoothstep(0.0, 0.4, h)) * sun_up * 0.5); // sunset glow
	col = mix(col, cloud_col, cover * 0.85);

	COLOR = vec4(col, 1.0);
}
