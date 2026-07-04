shader_type canvas_item;
// Wind sway for foliage sprites (trees, grass). A vertex bend offsets the TOP of each
// sprite horizontally while the base (UV.y ~ 1) stays rooted, keyed off a synced
// `wind_phase` fed from the GameClock by client/client_world.gd (like the sky/water),
// so every peer sees the same wind. `amp` scales the sway (small for trees, larger for
// grass); `spatial_k` desyncs neighbours by their world x.
// gl_compatibility-safe: only arithmetic + sin. (TAU/PI are Godot built-ins.)

uniform float wind_phase = 0.0;    // 0..1 synced wind phase
uniform float amp = 2.0;           // max horizontal sway at the top (px)
uniform float spatial_k = 0.015;   // per-world-px phase variation, so trees desync

void vertex() {
	// VERTEX is local space; the Foliage layers sit at the origin, so VERTEX == world px.
	float sway = amp * sin(wind_phase * TAU + VERTEX.x * spatial_k);
	VERTEX.x += sway * (1.0 - UV.y);   // top bends, base stays planted
}
