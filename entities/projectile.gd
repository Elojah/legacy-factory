class_name Projectile extends Node2D
## Visual shell for a KIND_PROJECTILE entity (a bolt). Server-spawned, simulated
## in the shared WorldSim, replicated via snapshots and interpolated like any
## remote entity — never trusted from the client. Holds NO simulation logic.
##
## Projectiles instantiate INSIDE snapshot frames, so all native resources come
## prebuilt: the animated core frames + shared additive material are cached by
## EffectSpawner._ready, and the glow sprite/material live in the .tscn.

var state: EntityState = EntityState.new()
var _sprite: AnimatedSprite2D
var _glow: Sprite2D

func setup(initial: EntityState, _mode: int) -> void:
	state = initial
	global_position = state.pos
	_sprite = $Sprite
	_glow = $Glow
	_sprite.sprite_frames = EffectSpawner.bolt_frames
	_sprite.play("fx")
	if state.ability_id == AbilityDefs.BOSS_BARRAGE:
		# Boss barrage shard: bigger, hotter — unmistakably not a player bolt.
		_sprite.modulate = Color(1.0, 0.55, 0.5)
		_sprite.scale = Vector2(1.5, 1.5)
		_glow.modulate = Color(1.0, 0.4, 0.25)
		_glow.scale = Vector2(0.65, 0.65)
	else:
		_glow.modulate = Color(1.0, 0.82, 0.45)
	_orient()

func apply_state(s: EntityState) -> void:
	state = s
	global_position = s.pos
	_orient()
	queue_redraw()

func _orient() -> void:
	# Cosmetic: point the trail along the flight direction.
	if state.vel.length() > 0.001:
		rotation = state.vel.angle()

func _draw() -> void:
	# Motion trail behind the animated core (drawn along -X; node is rotated).
	if state.ability_id == AbilityDefs.BOSS_BARRAGE:
		draw_line(Vector2(-14, 0), Vector2(-3, 0), Color(1.0, 0.45, 0.25, 0.55), 2.5)
	else:
		draw_line(Vector2(-11, 0), Vector2(-3, 0), Color(1.0, 0.85, 0.4, 0.5), 2.0)
