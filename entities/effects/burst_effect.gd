class_name BurstEffect extends Node2D
## Generic one-shot cast effect, drawn procedurally per effect id (no textures,
## no SpriteFrames — safe to instantiate inside snapshot/RPC handlers). Purely
## visual: locally timed with _process, never coupled to the sim. EffectSpawner
## positions/rotates us (+X = facing), calls configure(), and adds us; we play
## for DURATION seconds and free ourselves.

const DURATION: float = 0.3

var effect_id: int = EffectIds.BOLT_IMPACT
var _t: float = 0.0

func configure(p_effect_id: int) -> void:
	effect_id = p_effect_id

func _process(delta: float) -> void:
	_t += delta
	if _t >= DURATION:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var p := clampf(_t / DURATION, 0.0, 1.0)
	var fade := 1.0 - p
	match effect_id:
		EffectIds.BOLT_IMPACT:
			# Small flash: expanding core + four spokes.
			draw_circle(Vector2.ZERO, 2.0 + 6.0 * p, Color(1.0, 0.9, 0.5, 0.7 * fade))
			for i in 4:
				var dir := Vector2.RIGHT.rotated(TAU * float(i) / 4.0 + TAU * 0.125)
				draw_line(dir * 3.0, dir * (5.0 + 7.0 * p), Color(1.0, 1.0, 0.8, fade), 1.5)
		EffectIds.DASH_PUFF:
			# Chevrons trailing opposite the dash direction (-X), drifting back.
			for i in 3:
				var x := -4.0 - 6.0 * float(i) - 10.0 * p
				var a := fade * (1.0 - 0.25 * float(i))
				var c := Color(0.9, 0.95, 1.0, a * 0.8)
				draw_line(Vector2(x, 0), Vector2(x - 4, -4), c, 1.5)
				draw_line(Vector2(x, 0), Vector2(x - 4, 4), c, 1.5)
		EffectIds.HEAL_SPARKLE:
			# Green plus-signs rising from the caster.
			for i in 3:
				var off := Vector2(float(i - 1) * 7.0, -6.0 - 14.0 * p - 3.0 * float(i))
				var a := fade * (1.0 - 0.2 * float(i))
				var c := Color(0.4, 1.0, 0.5, a)
				draw_line(off + Vector2(-3, 0), off + Vector2(3, 0), c, 1.5)
				draw_line(off + Vector2(0, -3), off + Vector2(0, 3), c, 1.5)
		EffectIds.SLAM_RING:
			# Shockwave: a ring expanding out to the slam radius.
			var r := 8.0 + (AbilityDefs.SLAM_RADIUS - 8.0) * p
			draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(1.0, 0.6, 0.3, fade), 2.5)
			draw_arc(Vector2.ZERO, r * 0.7, 0.0, TAU, 32, Color(1.0, 0.8, 0.4, fade * 0.5), 1.5)
		EffectIds.BOSS_SMASH_RING:
			# Boss-scale double shockwave out to the smash radius.
			var r2 := 12.0 + (AbilityDefs.SMASH_RADIUS - 12.0) * p
			draw_arc(Vector2.ZERO, r2, 0.0, TAU, 56, Color(1.0, 0.45, 0.25, fade), 3.5)
			draw_arc(Vector2.ZERO, r2 * 0.75, 0.0, TAU, 48, Color(1.0, 0.7, 0.4, fade * 0.6), 2.0)
			draw_arc(Vector2.ZERO, r2 * 0.5, 0.0, TAU, 40, Color(1.0, 0.9, 0.6, fade * 0.35), 1.5)
		EffectIds.BOSS_SUMMON_BURST:
			# Dark motes scattering from the summon point.
			for i in 5:
				var off := Vector2.RIGHT.rotated(TAU * float(i) / 5.0) * (10.0 + 26.0 * p)
				draw_circle(off, 3.0 * fade + 0.5, Color(0.45, 0.25, 0.55, fade))
			draw_circle(Vector2.ZERO, 6.0 * (1.0 - p), Color(0.3, 0.15, 0.4, fade * 0.8))
		EffectIds.NOVA_RING:
			# Icy burst: a wide ring out to the nova radius + 8 flying sparks.
			var rn := 10.0 + (AbilityDefs.NOVA_RADIUS - 10.0) * p
			draw_arc(Vector2.ZERO, rn, 0.0, TAU, 48, Color(0.55, 0.8, 1.0, fade), 2.5)
			draw_arc(Vector2.ZERO, rn * 0.65, 0.0, TAU, 40, Color(0.75, 0.9, 1.0, fade * 0.5), 1.5)
			for i in 8:
				var off := Vector2.RIGHT.rotated(TAU * float(i) / 8.0) * rn
				draw_circle(off, 2.0 * fade + 0.5, Color(0.85, 0.95, 1.0, fade))
