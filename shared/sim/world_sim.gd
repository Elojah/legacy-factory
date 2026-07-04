class_name WorldSim
## THE DETERMINISM CONTRACT. The single authoritative+predicted step. Given the
## same starting states + same inputs, it produces identical results on client
## and server. Keep it pure: no Input, no rendering, no wall-clock, no nodes.
##
## `states`: Dictionary[int id -> EntityState] (mutated in place)
## `inputs`: Dictionary[int id -> InputCommand] (may be missing entries)
## `geometry`: the lobby's WorldGeometry — same instance on client and server, so
##   movement collision replays identically during prediction/reconciliation.
## `relations`: the lobby's FactionDefs 2-bit pair table — threaded like
##   `geometry` (server: Lobby field; client: latest snapshot header). Gates
##   player-vs-player damage and the heal splash. REQUIRED on purpose: a missed
##   call site must be a compile error, not a silent all-neutral.
##
## Entities are NEVER spawned or removed inside the step — projectile spawn and
## reaping are server-only policy in Lobby (ids are server-allocated; the
## predicting client must not invent entities). Projectile FLIGHT lives here so
## it stays shared deterministic code.
static func step(states: Dictionary, inputs: Dictionary, geometry: WorldGeometry, tick: int, relations: int) -> void:
	var ids := states.keys()
	ids.sort()  # deterministic processing order

	# 1) Consume inputs: ack, facing, ability start, movement. Actors only —
	#    projectiles fly, hazards tick, neither takes inputs.
	for id in ids:
		var s: EntityState = states[id]
		if not EntityDefs.is_actor(s.kind):
			continue
		var cmd: InputCommand = inputs.get(id, null)
		if cmd != null:
			s.last_input_seq = cmd.seq
		if not s.is_alive():
			s.vel = Vector2.ZERO
			continue
		if cmd == null:
			s.vel = Vector2.ZERO
			continue
		# Facing only updates while free to act (locked during the cast commit).
		if cmd.move.length() > 0.1 and (s.ability_phase == Ability.PHASE_IDLE or s.ability_phase == Ability.PHASE_RECOVERY):
			s.facing = cmd.move.normalized()
		var aid := _ability_for_buttons(cmd.buttons, s.upgrades)
		if aid != -1:
			Ability.try_start(s, aid)
		Movement.integrate(s, cmd, geometry)

	# 2) Fly projectiles: move, wall/TTL death, hit test.
	for id in ids:
		var s: EntityState = states[id]
		if s.kind == NetConfig.KIND_PROJECTILE and s.is_alive():
			_fly_projectile(s, states, ids, geometry, relations)

	# 2b) Tick hazards: TTL decay + periodic ground damage, keyed off the shared
	#     tick. Players only — boss zones never fry the boss's own minions
	#     (melee/AoE stay free-for-all). Client prediction never holds hazards
	#     (its dict is the local player only), so this pass is authority-driven
	#     and damage reaches the player via snapshots, like monster melee.
	for id in ids:
		var s: EntityState = states[id]
		if s.kind != NetConfig.KIND_HAZARD or not s.is_alive():
			continue
		s.ability_timer -= 1
		if s.ability_timer <= 0:
			s.hp = 0  # expired; the Lobby reaps it (same policy as projectiles)
			continue
		if tick % AbilityDefs.HAZARD_TICK_INTERVAL != 0:
			continue
		for tid in ids:
			var t: EntityState = states[tid]
			if t.kind != NetConfig.KIND_PLAYER or not t.is_alive():
				continue
			if s.pos.distance_to(t.pos) <= AbilityDefs.HAZARD_RADIUS + EntityDefs.radius_for(t.kind):
				t.hp = maxi(0, t.hp - AbilityDefs.HAZARD_DAMAGE)
				t.last_hit_by = s.owner_id

	# 3) Advance every actor's ability state machine one tick.
	for id in ids:
		var s: EntityState = states[id]
		if EntityDefs.is_actor(s.kind):
			Ability.advance(s)

	# 4) Resolve cast effects on the first ACTIVE tick.
	for id in ids:
		var s: EntityState = states[id]
		if not EntityDefs.is_actor(s.kind):
			continue
		if s.ability_phase != Ability.PHASE_ACTIVE or s.ability_has_hit:
			continue
		# BOSS_CHARGE resolves at the ARRIVAL tick (last ACTIVE tick), not the
		# first — the counterplay is dodging the landing zone, not the run-up.
		if s.ability_id == AbilityDefs.BOSS_CHARGE:
			if s.ability_timer == 1:
				for hid in HitboxResolver.resolve_radius(states, id, AbilityDefs.CHARGE_IMPACT_RADIUS, relations):
					var t: EntityState = states[hid]
					t.hp = maxi(0, t.hp - AbilityDefs.CHARGE_DAMAGE)
					t.last_hit_by = s.id
				s.ability_has_hit = true
			continue
		match s.ability_id:
			AbilityDefs.MELEE:
				for hid in HitboxResolver.resolve(states, id, relations):
					var t: EntityState = states[hid]
					t.hp = maxi(0, t.hp - UpgradeDefs.damage_for(AbilityDefs.MELEE, s.upgrades))
					t.last_hit_by = s.id
			AbilityDefs.SLAM:
				for hid in HitboxResolver.resolve_radius(states, id, AbilityDefs.SLAM_RADIUS, relations):
					var t: EntityState = states[hid]
					t.hp = maxi(0, t.hp - UpgradeDefs.damage_for(AbilityDefs.SLAM, s.upgrades))
					t.last_hit_by = s.id
			AbilityDefs.NOVA:
				for hid in HitboxResolver.resolve_radius(states, id, AbilityDefs.NOVA_RADIUS, relations):
					var t: EntityState = states[hid]
					t.hp = maxi(0, t.hp - UpgradeDefs.damage_for(AbilityDefs.NOVA, s.upgrades))
					t.last_hit_by = s.id
			AbilityDefs.BOSS_SMASH:
				for hid in HitboxResolver.resolve_radius(states, id, AbilityDefs.SMASH_RADIUS, relations):
					var t: EntityState = states[hid]
					t.hp = maxi(0, t.hp - AbilityDefs.SMASH_DAMAGE)
					t.last_hit_by = s.id
			AbilityDefs.HEAL:
				s.hp = mini(EntityDefs.max_hp_of(s), s.hp + UpgradeDefs.heal_for(s.upgrades))
				# Alliance perk: splash the heal to nearby same-faction/allied
				# players. Players only, sorted ids — deterministic. The client
				# never predicts this for others (its dict holds only the local
				# player); allies' hp arrives via snapshots like all remote hp.
				if s.kind == NetConfig.KIND_PLAYER:
					for tid in ids:
						if tid == id:
							continue
						var ht: EntityState = states[tid]
						if ht.kind != NetConfig.KIND_PLAYER or not ht.is_alive():
							continue
						if not FactionDefs.are_allied(s.faction, ht.faction, relations):
							continue
						if s.pos.distance_to(ht.pos) <= AbilityDefs.HEAL_SPLASH_RADIUS + EntityDefs.radius_for(ht.kind):
							ht.hp = mini(EntityDefs.max_hp_of(ht), ht.hp + UpgradeDefs.heal_for(s.upgrades))
			# BOLT / VOLLEY / BOSS_BARRAGE / BOSS_SUMMON / BOSS_HAZARD: the
			# entities are spawned by the server (Lobby) on this same first
			# ACTIVE tick; nothing happens inside the step itself.
			# DASH: the effect is the Movement override while ACTIVE.
		s.ability_has_hit = true

## Deterministic button -> ability priority ladder (lowest bit wins) so client
## prediction and server authority pick the same ability from the same command.
## NOVA/VOLLEY additionally require their unlock bit in `upgrades` — a locked
## press falls through identically on both ends (upgrades is sim-read + synced).
static func _ability_for_buttons(buttons: int, upgrades: int) -> int:
	if (buttons & NetConfig.BTN_ATTACK) != 0:
		return AbilityDefs.MELEE
	if (buttons & NetConfig.BTN_BOLT) != 0:
		return AbilityDefs.BOLT
	if (buttons & NetConfig.BTN_DASH) != 0:
		return AbilityDefs.DASH
	if (buttons & NetConfig.BTN_HEAL) != 0:
		return AbilityDefs.HEAL
	if (buttons & NetConfig.BTN_SLAM) != 0:
		return AbilityDefs.SLAM
	if (buttons & NetConfig.BTN_NOVA) != 0 and UpgradeDefs.has_skill(upgrades, AbilityDefs.NOVA):
		return AbilityDefs.NOVA
	if (buttons & NetConfig.BTN_VOLLEY) != 0 and UpgradeDefs.has_skill(upgrades, AbilityDefs.VOLLEY):
		return AbilityDefs.VOLLEY
	# Boss pool: AI-only bits (push_input strips them from player input).
	if (buttons & NetConfig.BTN_BOSS_SMASH) != 0:
		return AbilityDefs.BOSS_SMASH
	if (buttons & NetConfig.BTN_BOSS_BARRAGE) != 0:
		return AbilityDefs.BOSS_BARRAGE
	if (buttons & NetConfig.BTN_BOSS_SUMMON) != 0:
		return AbilityDefs.BOSS_SUMMON
	if (buttons & NetConfig.BTN_BOSS_HAZARD) != 0:
		return AbilityDefs.BOSS_HAZARD
	if (buttons & NetConfig.BTN_BOSS_CHARGE) != 0:
		return AbilityDefs.BOSS_CHARGE
	return -1

## One tick of projectile flight. `ability_timer` is the remaining TTL. Death is
## hp = 0; the Lobby reaps dead projectiles after the step (server-only policy).
static func _fly_projectile(s: EntityState, states: Dictionary, ids: Array, geometry: WorldGeometry, relations: int) -> void:
	s.pos += s.vel * NetConfig.DT
	# Leaving the walkable union means hitting a wall/edge: die in place.
	# (resolve_circle returns the position unchanged while it stays inside.)
	if geometry.resolve_circle(s.pos, AbilityDefs.BOLT_RADIUS) != s.pos:
		s.hp = 0
		return
	s.ability_timer -= 1
	if s.ability_timer <= 0:
		s.hp = 0
		return
	for id in ids:
		if id == s.owner_id or id == s.id:
			continue
		var t: EntityState = states[id]
		if not EntityDefs.is_targetable(t.kind) or not t.is_alive():
			continue
		var hit_reach := EntityDefs.radius_for(t.kind) + AbilityDefs.BOLT_RADIUS
		# A summoner's projectiles never hit its own summons (barrage vs minions).
		if t.owner_id != 0 and t.owner_id == s.owner_id:
			continue
		# Non-hostile players are passed THROUGH: no damage AND no absorb, so a
		# neutral body can't shield a rival. Projectile faction = caster's.
		if not FactionDefs.are_hostile(s.faction, t.faction, relations):
			continue
		if s.pos.distance_to(t.pos) <= hit_reach:  # lowest id wins (sorted ids)
			t.hp = maxi(0, t.hp - UpgradeDefs.projectile_damage_for(s.ability_id, s.upgrades))
			t.last_hit_by = s.owner_id  # credit the caster, not the projectile
			s.hp = 0
			return
