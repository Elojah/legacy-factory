class_name Projectile extends Node2D
## Visual shell for a KIND_PROJECTILE entity (a bolt). Server-spawned, simulated
## in the shared WorldSim, replicated via snapshots and interpolated like any
## remote entity — never trusted from the client. Holds NO simulation logic;
## it just draws whatever EntityState it is handed.

var state: EntityState = EntityState.new()

func setup(initial: EntityState, _mode: int) -> void:
	state = initial
	global_position = state.pos
	_orient()

func apply_state(s: EntityState) -> void:
	state = s
	global_position = s.pos
	_orient()
	queue_redraw()

func _orient() -> void:
	# Cosmetic: point the streak along the flight direction.
	if state.vel.length() > 0.001:
		rotation = state.vel.angle()

func _draw() -> void:
	if state.ability_id == AbilityDefs.BOSS_BARRAGE:
		# Boss barrage shard: bigger, hotter — unmistakably not a player bolt.
		draw_line(Vector2(-12, 0), Vector2(-2, 0), Color(1.0, 0.45, 0.25, 0.55), 2.5)
		draw_circle(Vector2.ZERO, 3.5, Color(1.0, 0.5, 0.3))
		draw_circle(Vector2.ZERO, 1.8, Color(1.0, 0.85, 0.7))
		return
	# Bright core + short trailing streak (drawn along -X; node is rotated).
	draw_line(Vector2(-10, 0), Vector2(-2, 0), Color(1.0, 0.85, 0.4, 0.5), 2.0)
	draw_circle(Vector2.ZERO, 3.0, Color(1.0, 0.95, 0.6))
	draw_circle(Vector2.ZERO, 1.5, Color(1.0, 1.0, 0.9))
