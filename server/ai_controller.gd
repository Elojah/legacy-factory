class_name AIController extends RefCounted
## Produces InputCommands for monster entities. Monsters feed the SAME WorldSim
## as players, so PvE and PvP run under identical authoritative rules.
##
## Monsters are territorial: they only aggro players inside MONSTER_AGGRO_RADIUS
## and walk back to their home point (spawn / summon spot) when out of combat or
## dragged past MONSTER_LEASH_RADIUS. This keeps each island's danger tier where
## the generator put it — without a leash the whole map would beeline onto the
## nearest player across the (now dense) bridge network.

const MONSTER_AGGRO_RADIUS: float = 260.0
const MONSTER_LEASH_RADIUS: float = 420.0   # beyond this from home: disengage, walk back
const MONSTER_HOME_EPS: float = 4.0         # close enough to home to stop

func produce(states: Dictionary, inputs: Dictionary, homes: Dictionary) -> void:
	var ids := states.keys()
	ids.sort()
	var attack_range := AbilityDefs.MELEE_RANGE * 0.8 + EntityDefs.radius_for(NetConfig.KIND_MONSTER)
	for id in ids:
		var s: EntityState = states[id]
		if s.kind != NetConfig.KIND_MONSTER or not s.is_alive():
			continue
		var home: Vector2 = homes.get(id, s.pos)
		var dist_home := s.pos.distance_to(home)
		var target := _nearest_player(states, s)
		if target == null or dist_home > MONSTER_LEASH_RADIUS:
			# Out of combat (or leashed): walk home and never attack on the way.
			var move_home := Vector2.ZERO
			if dist_home > MONSTER_HOME_EPS:
				move_home = (home - s.pos) / dist_home
			inputs[id] = InputCommand.create(0, 0, move_home, 0)
			continue
		var move := Vector2.ZERO
		var buttons := 0
		var to := target.pos - s.pos
		var dist := to.length()
		if dist > 0.001:
			move = to / dist  # face/move toward the target
		if dist <= attack_range and s.ability_phase == Ability.PHASE_IDLE and s.ability_cds[AbilityDefs.MELEE] == 0:
			buttons |= NetConfig.BTN_ATTACK
		inputs[id] = InputCommand.create(0, 0, move, buttons)

## Nearest living player, capped at MONSTER_AGGRO_RADIUS (mirrors BossAI).
func _nearest_player(states: Dictionary, from: EntityState) -> EntityState:
	var best: EntityState = null
	var best_d := INF
	for id in states:
		var t: EntityState = states[id]
		if t.kind != NetConfig.KIND_PLAYER or not t.is_alive():
			continue
		var d := from.pos.distance_squared_to(t.pos)
		if d < best_d:
			best_d = d
			best = t
	if best != null and best_d > MONSTER_AGGRO_RADIUS * MONSTER_AGGRO_RADIUS:
		return null
	return best
