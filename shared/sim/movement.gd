class_name Movement
## Pure, deterministic movement integration. Uses NetConfig.DT (never frame
## delta) and explicit collision math (never the physics engine) so the exact
## same code runs in client prediction and server authority.

static func speed_for(s: EntityState) -> float:
	match s.kind:
		NetConfig.KIND_PLAYER:
			# SWIFT passive: const float multiply — identical on both ends.
			# Dash/charge override speeds are intentionally unaffected.
			if UpgradeDefs.has_passive(s.upgrades, UpgradeDefs.BIT_SWIFT):
				return NetConfig.PLAYER_SPEED * UpgradeDefs.SWIFT_SPEED_MULT
			return NetConfig.PLAYER_SPEED
		NetConfig.KIND_BOSS:
			return NetConfig.BOSS_SPEED
		_:
			return NetConfig.MONSTER_SPEED

## Integrate one tick of movement for `s` given `cmd`, colliding against
## `geometry` (the lobby's world; identical instance on client and server).
static func integrate(s: EntityState, cmd: InputCommand, geometry: WorldGeometry) -> void:
	if not s.is_alive():
		s.vel = Vector2.ZERO
		return
	var override_speed := AbilityDefs.movement_override_speed(s)
	if override_speed > 0.0:
		# Dash/charge: burst along facing; input is ignored for the duration.
		# Facing is already locked during ACTIVE, so the burst cannot curve.
		var dir := s.facing.normalized() if s.facing.length() > 0.001 else Vector2.DOWN
		s.vel = dir * override_speed
	else:
		var move := cmd.move
		if move.length() > 1.0:
			move = move.normalized()
		var speed := 0.0 if Ability.is_rooted(s) else speed_for(s)
		s.vel = move * speed
	s.pos += s.vel * NetConfig.DT
	s.pos = geometry.resolve_circle(s.pos, EntityDefs.radius_for(s.kind))
