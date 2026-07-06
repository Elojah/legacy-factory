shader_type canvas_item;
// Wind sway for foliage sprites (trees, grass). A vertex bend offsets the TOP of each
// sprite horizontally while the base stays rooted, keyed off a synced `wind_phase`
// fed from the GameClock by client/client_world.gd (like the sky/water), so every
// peer sees the same wind. `amp` scales the sway (small for trees, larger for grass);
// `spatial_k` desyncs neighbours by their world x. Sway is keyed on WORLD x via
// MODEL_MATRIX so it works both for the batch grass layer (identity transform:
// VERTEX == world px) and for individual tree Sprite2Ds in the y-sorted Playfield.
// `base_v` is the UV.y of the sprite's rooted base: 1.0 for region sprites (UV spans
// the region), 0.5 for the grass batch (row 0 of the 2-row foliage atlas).
// gl_compatibility-safe: only arithmetic + sin. (TAU/PI are Godot built-ins.)

uniform float wind_phase = 0.0;    // 0..1 synced wind phase
uniform float amp = 2.0;           // max horizontal sway at the top (px)
uniform float spatial_k = 0.015;   // per-world-px phase variation, so trees desync
uniform float base_v = 1.0;        // UV.y at the rooted base

void vertex() {
	float wx = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).x;
	float sway = amp * sin(wind_phase * TAU + wx * spatial_k);
	float bend = clamp(1.0 - UV.y / max(base_v, 0.001), 0.0, 1.0);
	VERTEX.x += sway * bend;
}
