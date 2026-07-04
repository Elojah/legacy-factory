class_name Hazard extends Node2D
## Visual shell for a KIND_HAZARD entity (a boss ground zone). Server-spawned,
## TTL-ticked in the shared WorldSim, replicated via snapshots and interpolated
## like any remote entity. Holds NO simulation logic; it draws whatever
## EntityState it is handed, kit-tinted via the appearance field and fading as
## its TTL (ability_timer) runs out. z-indexed under actors: it paints the
## ground, not the feet.

var state: EntityState = EntityState.new()

func setup(initial: EntityState, _mode: int) -> void:
	state = initial
	global_position = state.pos
	z_index = -1

func apply_state(s: EntityState) -> void:
	state = s
	global_position = s.pos
	queue_redraw()

func _draw() -> void:
	var col := BossPalette.color_for(state.appearance)
	var frac := clampf(float(state.ability_timer) / float(AbilityDefs.HAZARD_TTL_TICKS), 0.0, 1.0)
	var fade := clampf(frac * 6.0, 0.0, 1.0)   # fade out over the last second
	var pulse := 0.9 + 0.1 * sin(float(state.ability_timer) * 0.35)
	var r := AbilityDefs.HAZARD_RADIUS
	draw_circle(Vector2.ZERO, r * pulse, Color(col.r, col.g, col.b, 0.25 * fade))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.8 * fade), 2.0)
	draw_arc(Vector2.ZERO, r * 0.55 * pulse, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.45 * fade), 1.5)
	draw_circle(Vector2.ZERO, 3.0, Color(1.0, 1.0, 0.9, 0.6 * fade))
