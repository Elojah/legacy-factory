class_name Hazard extends Node2D
## Visual shell for a KIND_HAZARD entity (a boss ground zone). Server-spawned,
## TTL-ticked in the shared WorldSim, replicated via snapshots and interpolated
## like any remote entity. Holds NO simulation logic; it draws whatever
## EntityState it is handed, kit-tinted via the appearance field and fading as
## its TTL (ability_timer) runs out. z-indexed under actors: it paints the
## ground, not the feet.
##
## Hazards instantiate INSIDE snapshot frames — the animated swirl frames and
## the shared additive material come prebuilt from EffectSpawner._ready.

var state: EntityState = EntityState.new()
var _swirl: AnimatedSprite2D
var _kit_col: Color = Color.WHITE

func setup(initial: EntityState, _mode: int) -> void:
	state = initial
	global_position = state.pos
	z_index = -1
	_kit_col = BossPalette.color_for(state.appearance)
	_swirl = $Swirl
	_swirl.sprite_frames = EffectSpawner.hazard_frames
	_swirl.material = EffectSpawner.additive_mat
	_swirl.modulate = _kit_col
	_swirl.scale = Vector2.ONE * (AbilityDefs.HAZARD_RADIUS / 20.0)
	_swirl.play("swirl")

func apply_state(s: EntityState) -> void:
	state = s
	global_position = s.pos
	queue_redraw()

func _draw() -> void:
	var col := _kit_col
	var frac := clampf(float(state.ability_timer) / float(AbilityDefs.HAZARD_TTL_TICKS), 0.0, 1.0)
	var fade := clampf(frac * 6.0, 0.0, 1.0)   # fade out over the last second
	var pulse := 0.9 + 0.1 * sin(float(state.ability_timer) * 0.35)
	var r := AbilityDefs.HAZARD_RADIUS
	if _swirl != null:
		_swirl.modulate = Color(col.r, col.g, col.b, fade)
	draw_circle(Vector2.ZERO, r * pulse, Color(col.r, col.g, col.b, 0.22 * fade))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.8 * fade), 2.0)
	draw_circle(Vector2.ZERO, 3.0, Color(1.0, 1.0, 0.9, 0.6 * fade))
