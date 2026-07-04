class_name BossAI extends RefCounted
## Server-only pattern driver for KIND_BOSS entities. Like AIController it emits
## InputCommands into the same inputs dict WorldSim consumes (bosses obey the
## exact same authoritative rules as everyone else); unlike the slimes it plays
## a per-kit, per-phase scripted move cycle. All memory lives here on the server
## — nothing about AI state ever touches the wire.

var _mem: Dictionary = {}   # boss_id -> {"step": int, "phase": int, "home": Vector2, "kit": int}

func register(boss_id: int, home: Vector2, kit: int) -> void:
	_mem[boss_id] = {"step": 0, "phase": 0, "home": home, "kit": kit}

## Back to the phase-opener (on death or a raid reset).
func reset(boss_id: int) -> void:
	if _mem.has(boss_id):
		_mem[boss_id]["step"] = 0
		_mem[boss_id]["phase"] = 0

func produce(states: Dictionary, inputs: Dictionary) -> void:
	var ids := states.keys()
	ids.sort()
	for id in ids:
		var s: EntityState = states[id]
		if s.kind != NetConfig.KIND_BOSS or not s.is_alive() or not _mem.has(id):
			continue
		var m: Dictionary = _mem[id]
		# Phase from hp fraction of THIS boss's tiered max (danger tier rides
		# upgrades bits 0-1); a phase change restarts the cycle on that phase's
		# scripted opener.
		var phase := BossDefs.phase_for_hp(s.hp, EntityDefs.max_hp_of(s))
		if phase != int(m["phase"]):
			m["phase"] = phase
			m["step"] = 0
		# Mid-cast: hold still (rooted anyway; charge ignores input while ACTIVE).
		if s.ability_phase != Ability.PHASE_IDLE:
			inputs[id] = InputCommand.create(0, 0, Vector2.ZERO, 0)
			continue
		var home: Vector2 = m["home"]
		var dist_home := s.pos.distance_to(home)
		var target := _nearest_player(states, s)
		if target == null or dist_home > BossDefs.LEASH_RADIUS:
			# Out of combat (or dragged off the arena): walk home. The Lobby's
			# reset policy re-heals it once it stands at home with nobody near.
			var move_home := Vector2.ZERO
			if dist_home > 4.0:
				move_home = (home - s.pos) / dist_home
			inputs[id] = InputCommand.create(0, 0, move_home, 0)
			continue
		var to := target.pos - s.pos
		var dist := to.length()
		var dir := to / dist if dist > 0.001 else Vector2.DOWN
		# Pick the next off-cooldown move in the cycle (bounded one-cycle scan).
		var cycle := BossDefs.pattern(int(m["kit"]), phase)
		var step := int(m["step"])
		var pending := -1
		for k in cycle.size():
			var btn: int = cycle[(step + k) % cycle.size()]
			if s.ability_cds[BossDefs.ability_for_button(btn)] == 0:
				pending = btn
				step = (step + k) % cycle.size()
				break
		if pending == -1:
			# Whole kit on cooldown: lumber toward the target.
			var chase := dir if dist > 60.0 else Vector2.ZERO
			inputs[id] = InputCommand.create(0, 0, chase, 0)
			continue
		# Range gate: smash wants the target inside its ring, charge refuses
		# point-blank. Walk to satisfy the pending move instead of skipping it.
		var aid := BossDefs.ability_for_button(pending)
		var in_range := true
		if aid == AbilityDefs.BOSS_SMASH:
			in_range = dist <= AbilityDefs.SMASH_RADIUS
		elif aid == AbilityDefs.BOSS_CHARGE:
			in_range = dist >= BossDefs.CHARGE_MIN_RANGE
		var move := Vector2.ZERO
		var buttons := 0
		if in_range:
			buttons = pending
			move = dir  # aims the cast: facing follows move on this same tick
			m["step"] = (step + 1) % cycle.size()
		else:
			move = dir if aid == AbilityDefs.BOSS_SMASH else -dir
		inputs[id] = InputCommand.create(0, 0, move, buttons)

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
	if best != null and best_d > BossDefs.AGGRO_RADIUS * BossDefs.AGGRO_RADIUS:
		return null
	return best
