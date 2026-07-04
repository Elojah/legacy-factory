extends SceneTree
## Standalone deterministic test for the shared skill sim. Run with:
##   godot-4 --headless --path . --script res://tools/test_skills.gd
## Exercises the generalized ability machine through WorldSim.step exactly as
## client prediction / server authority do: melee regression, button priority,
## dash movement + replay determinism, heal cap + cooldown rejection, slam
## multi-target radius, bolt flight (hit / TTL / wall), faction relations
## (packing, PvP gating, projectile passthrough, heal splash), and EntityState
## serialization round-trip (the reconciliation keystone).

var _fails: int = 0
var _checks: int = 0

func _initialize() -> void:
	_test_serialization_roundtrip()
	_test_clone_no_aliasing()
	_test_melee_regression()
	_test_button_priority()
	_test_dash()
	_test_dash_replay_determinism()
	_test_heal()
	_test_slam()
	_test_bolt_hit()
	_test_bolt_ttl()
	_test_bolt_wall()
	_test_boss_smash()
	_test_boss_charge()
	_test_boss_melee_reach()
	_test_boss_spawn_edges()
	_test_hazard_tick()
	_test_bolt_over_hazard()
	_test_barrage_projectile()
	_test_relation_packing()
	_test_faction_melee_gating()
	_test_faction_bolt_passthrough()
	_test_heal_splash()
	_test_boss_vs_factions()
	_test_upgrade_packing()
	_test_upgrade_scaling()
	_test_swift_speed()
	_test_nova()
	_test_volley()
	_test_upgrade_replay_determinism()
	_test_last_hit_credit()

	print("skills test: %d checks, %d failures" % [_checks, _fails])
	print("RESULT: %s" % ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)

# --- helpers -------------------------------------------------------------------
func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL %s" % label)

## One big open field: no walls anywhere near the action.
func _open_geometry() -> WorldGeometry:
	var g := WorldGeometry.new()
	g.walkable.append(Rect2(0, 0, 4000, 4000))
	g.bounds = Rect2(0, 0, 4000, 4000)
	return g

func _entity(id: int, kind: int, pos: Vector2, hp: int) -> EntityState:
	var s := EntityState.new()
	s.id = id
	s.kind = kind
	s.pos = pos
	s.hp = hp
	return s

func _cmd(move: Vector2, buttons: int) -> InputCommand:
	return InputCommand.create(0, 0, move, buttons)

## Step `states` for `ticks`, feeding entity 1 the same command every tick.
func _run(states: Dictionary, geometry: WorldGeometry, cmd_for_1: InputCommand, ticks: int, relations: int = 0) -> void:
	for t in ticks:
		var inputs := {}
		if cmd_for_1 != null:
			inputs[1] = cmd_for_1
		WorldSim.step(states, inputs, geometry, t, relations)

## Ticks from cast start until the effect lands (first ACTIVE tick).
func _ticks_to_active(aid: int) -> int:
	return maxi(AbilityDefs.WINDUP_TICKS[aid], 1)

# --- serialization ---------------------------------------------------------------
func _test_serialization_roundtrip() -> void:
	var s := _entity(7, NetConfig.KIND_PROJECTILE, Vector2(123.5, -40.25), 1)
	s.vel = Vector2(360, 0)
	s.ability_id = AbilityDefs.BOLT
	s.ability_phase = Ability.PHASE_ACTIVE
	s.ability_timer = 33
	s.ability_has_hit = true
	s.owner_id = 42
	s.last_input_seq = 100000
	s.faction = 3
	s.upgrades = 0x5ABC & UpgradeDefs.UPGRADES_MASK
	s.last_hit_by = 77
	for i in AbilityDefs.ABILITY_COUNT:
		s.ability_cds[i] = 10 * (i + 1)
	var buf := PackedByteArray()
	s.write_into(buf)
	_check(buf.size() == 54, "roundtrip: entity is 54 bytes on the wire (got %d)" % buf.size())
	var r := Serialization.reader(buf)
	var d := EntityState.read_from(r)
	_check(d.id == s.id and d.kind == s.kind and d.owner_id == s.owner_id, "roundtrip: id/kind/owner")
	_check(d.ability_id == s.ability_id and d.ability_phase == s.ability_phase \
		and d.ability_timer == s.ability_timer and d.ability_has_hit == s.ability_has_hit, "roundtrip: ability core")
	_check(d.ability_cds == s.ability_cds, "roundtrip: per-slot cooldowns")
	_check(d.hp == s.hp and d.last_input_seq == s.last_input_seq, "roundtrip: hp/seq")
	_check(d.faction == 3, "roundtrip: faction survives")
	_check(d.upgrades == s.upgrades, "roundtrip: upgrades survive")
	_check(d.last_hit_by == 0, "roundtrip: last_hit_by is NOT on the wire (server-only)")

func _test_clone_no_aliasing() -> void:
	var s := _entity(1, NetConfig.KIND_PLAYER, Vector2.ZERO, 100)
	s.ability_cds[AbilityDefs.HEAL] = 99
	s.upgrades = UpgradeDefs.BIT_NOVA | UpgradeDefs.BIT_SWIFT
	s.last_hit_by = 42
	var c := s.clone()
	s.ability_cds[AbilityDefs.HEAL] = 5
	_check(c.ability_cds[AbilityDefs.HEAL] == 99, "clone: ability_cds must not alias (duplicate)")
	_check(c.upgrades == s.upgrades and c.last_hit_by == 42, "clone: upgrades/last_hit_by copied")

# --- melee (regression) -----------------------------------------------------------
func _test_melee_regression() -> void:
	var g := _open_geometry()
	var atk := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	atk.facing = Vector2.RIGHT
	var tgt := _entity(2, NetConfig.KIND_MONSTER, Vector2(530, 500), 120)
	var states := {1: atk, 2: tgt}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK), _ticks_to_active(AbilityDefs.MELEE) + 1)
	_check(tgt.hp == 120 - AbilityDefs.MELEE_DAMAGE, "melee: target damaged once (got hp %d)" % tgt.hp)
	# Full cycle charges the melee cooldown only.
	_run(states, g, null, AbilityDefs.ACTIVE_TICKS[AbilityDefs.MELEE] + AbilityDefs.RECOVERY_TICKS[AbilityDefs.MELEE] + 1)
	_check(atk.ability_cds[AbilityDefs.MELEE] > 0, "melee: cooldown charged after recovery")
	_check(atk.ability_cds[AbilityDefs.HEAL] == 0, "melee: other slots untouched")
	_check(tgt.hp == 120 - AbilityDefs.MELEE_DAMAGE, "melee: no double damage")

# --- button priority ---------------------------------------------------------------
func _test_button_priority() -> void:
	var g := _open_geometry()
	var s := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	var states := {1: s}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL | NetConfig.BTN_ATTACK), 1)
	_check(s.ability_id == AbilityDefs.MELEE and s.ability_phase != Ability.PHASE_IDLE,
		"priority: ATTACK wins over HEAL when both held")

# --- dash ---------------------------------------------------------------------------
func _test_dash() -> void:
	var g := _open_geometry()
	var s := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	s.facing = Vector2.RIGHT
	var states := {1: s}
	var x0 := s.pos.x
	# Press tick: 0-tick windup goes ACTIVE within the same step.
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_DASH), 1)
	_check(s.ability_id == AbilityDefs.DASH and s.ability_phase == Ability.PHASE_ACTIVE,
		"dash: ACTIVE on the press tick")
	# ACTIVE ticks: moves at DASH_SPEED along facing, ignoring held input (UP).
	_run(states, g, _cmd(Vector2.UP, NetConfig.BTN_DASH), AbilityDefs.ACTIVE_TICKS[AbilityDefs.DASH])
	var expected := AbilityDefs.DASH_SPEED * NetConfig.DT * float(AbilityDefs.ACTIVE_TICKS[AbilityDefs.DASH])
	_check(absf((s.pos.x - x0) - expected) < 0.01, "dash: displacement %.2f expected %.2f" % [s.pos.x - x0, expected])
	_check(absf(s.pos.y - 500.0) < 0.01, "dash: input direction ignored while dashing")
	_run(states, g, null, AbilityDefs.RECOVERY_TICKS[AbilityDefs.DASH] + 1)
	_check(s.ability_cds[AbilityDefs.DASH] > 0, "dash: cooldown charged")

## The reconciliation contract: replaying the same commands from a copied state
## must land on a byte-identical result (dash is the movement-heavy case).
func _test_dash_replay_determinism() -> void:
	var g := _open_geometry()
	var a := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	a.facing = Vector2.RIGHT
	var b := a.clone()
	var cmds: Array = []
	for t in 12:
		cmds.append(_cmd(Vector2.DOWN if t > 6 else Vector2.ZERO, NetConfig.BTN_DASH if t < 2 else 0))
	for c in cmds:
		WorldSim.step({1: a}, {1: c}, g, 0, 0)
	for c in cmds:
		WorldSim.step({1: b}, {1: c}, g, 0, 0)
	var ba := PackedByteArray()
	var bb := PackedByteArray()
	a.write_into(ba)
	b.write_into(bb)
	_check(ba == bb, "dash replay: byte-identical after identical inputs from a clone")

# --- heal ----------------------------------------------------------------------------
func _test_heal() -> void:
	var g := _open_geometry()
	var s := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 50)
	var states := {1: s}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL), _ticks_to_active(AbilityDefs.HEAL) + 1)
	_check(s.hp == 50 + AbilityDefs.HEAL_AMOUNT, "heal: +%d hp (got %d)" % [AbilityDefs.HEAL_AMOUNT, s.hp])
	# Finish the cast, then spam: cooldown must reject (server-authority test).
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL), 60)
	_check(s.hp == 50 + AbilityDefs.HEAL_AMOUNT, "heal: spam on cooldown never re-heals")
	_check(s.ability_cds[AbilityDefs.HEAL] > 0, "heal: long cooldown charged")
	# Cap at max HP.
	var s2 := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), NetConfig.PLAYER_MAX_HP - 5)
	var states2 := {1: s2}
	_run(states2, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL), _ticks_to_active(AbilityDefs.HEAL) + 1)
	_check(s2.hp == NetConfig.PLAYER_MAX_HP, "heal: capped at max hp (got %d)" % s2.hp)

# --- slam ----------------------------------------------------------------------------
func _test_slam() -> void:
	var g := _open_geometry()
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	var near1 := _entity(2, NetConfig.KIND_MONSTER, Vector2(540, 500), 120)   # inside radius
	var near2 := _entity(3, NetConfig.KIND_MONSTER, Vector2(500, 560), 120)   # inside (radius+entity radius)
	var far := _entity(4, NetConfig.KIND_MONSTER, Vector2(700, 500), 120)     # outside
	var states := {1: caster, 2: near1, 3: near2, 4: far}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_SLAM), _ticks_to_active(AbilityDefs.SLAM) + 1)
	_check(near1.hp == 120 - AbilityDefs.SLAM_DAMAGE, "slam: near target 1 hit (got %d)" % near1.hp)
	_check(near2.hp == 120 - AbilityDefs.SLAM_DAMAGE, "slam: near target 2 hit (got %d)" % near2.hp)
	_check(far.hp == 120, "slam: far target untouched")

# --- bolt ----------------------------------------------------------------------------
## Mirror Lobby._spawn_bolts for one caster (the lobby spawn itself is server
## policy; here we exercise the shared flight sim it feeds).
func _spawn_bolt_for(caster: EntityState, id: int) -> EntityState:
	var dir := caster.facing.normalized() if caster.facing.length() > 0.001 else Vector2.DOWN
	var b := EntityState.new()
	b.id = id
	b.kind = NetConfig.KIND_PROJECTILE
	b.hp = 1
	b.owner_id = caster.id
	b.ability_id = AbilityDefs.BOLT
	b.upgrades = caster.upgrades  # damage scales off the caster's BOLT level
	b.facing = dir
	b.vel = dir * AbilityDefs.BOLT_SPEED
	b.pos = caster.pos + dir * (NetConfig.ENTITY_RADIUS + AbilityDefs.BOLT_RADIUS + AbilityDefs.BOLT_SPAWN_GAP)
	b.ability_timer = AbilityDefs.BOLT_TTL_TICKS
	return b

func _cast_bolt_and_spawn(states: Dictionary, g: WorldGeometry) -> EntityState:
	# Drive the caster through the whole cast window, asserting the spawn-edge
	# condition Lobby uses fires exactly once. The bolt is inserted only after
	# the window so callers observe its full TTL.
	var edges := 0
	var bolt: EntityState = null
	for t in AbilityDefs.WINDUP_TICKS[AbilityDefs.BOLT] + AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOLT] + 2:
		WorldSim.step(states, {1: _cmd(Vector2.ZERO, NetConfig.BTN_BOLT)}, g, t, 0)
		var c: EntityState = states[1]
		if c.ability_id == AbilityDefs.BOLT and c.ability_phase == Ability.PHASE_ACTIVE \
		and c.ability_timer == AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOLT]:
			edges += 1
			if bolt == null:
				bolt = _spawn_bolt_for(c, 99)
	_check(edges == 1, "bolt: spawn edge fires exactly once (got %d)" % edges)
	if bolt != null:
		states[99] = bolt
	return bolt

func _test_bolt_hit() -> void:
	var g := _open_geometry()
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	caster.facing = Vector2.RIGHT
	var tgt := _entity(2, NetConfig.KIND_MONSTER, Vector2(700, 500), 120)
	var states := {1: caster, 2: tgt}
	var bolt := _cast_bolt_and_spawn(states, g)
	_check(bolt != null and bolt.is_alive(), "bolt: spawned alive")
	for t in AbilityDefs.BOLT_TTL_TICKS:
		if not bolt.is_alive():
			break
		WorldSim.step(states, {}, g, t, 0)
	_check(tgt.hp == 120 - AbilityDefs.BOLT_DAMAGE, "bolt: target hit for %d (got hp %d)" % [AbilityDefs.BOLT_DAMAGE, tgt.hp])
	_check(bolt.hp == 0, "bolt: dies on hit")
	_check(caster.hp == 100, "bolt: never hits its owner")

func _test_bolt_ttl() -> void:
	var g := _open_geometry()
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	caster.facing = Vector2.RIGHT
	var states := {1: caster}
	var bolt := _cast_bolt_and_spawn(states, g)
	var flew := 0
	for t in AbilityDefs.BOLT_TTL_TICKS + 5:
		if not bolt.is_alive():
			break
		WorldSim.step(states, {}, g, t, 0)
		flew += 1
	_check(bolt.hp == 0 and flew == AbilityDefs.BOLT_TTL_TICKS, "bolt: expires after TTL (flew %d)" % flew)

func _test_bolt_wall() -> void:
	var g := _open_geometry()
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(3950, 500), 100)  # near the east edge
	caster.facing = Vector2.RIGHT
	var states := {1: caster}
	var bolt := _cast_bolt_and_spawn(states, g)
	var flew := 0
	for t in AbilityDefs.BOLT_TTL_TICKS:
		if not bolt.is_alive():
			break
		WorldSim.step(states, {}, g, t, 0)
		flew += 1
	_check(bolt.hp == 0 and flew < AbilityDefs.BOLT_TTL_TICKS, "bolt: dies at the wall (flew %d)" % flew)
	_check(bolt.pos.x <= 4000.0, "bolt: never leaves the walkable union")

# --- boss pool ------------------------------------------------------------------------
func _test_boss_smash() -> void:
	var g := _open_geometry()
	var boss := _entity(1, NetConfig.KIND_BOSS, Vector2(500, 500), NetConfig.BOSS_MAX_HP)
	var near := _entity(2, NetConfig.KIND_PLAYER, Vector2(590, 500), 100)   # dist 90 <= 90+8
	var far := _entity(3, NetConfig.KIND_PLAYER, Vector2(610, 500), 100)    # dist 110 > 98
	var states := {1: boss, 2: near, 3: far}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_BOSS_SMASH), _ticks_to_active(AbilityDefs.BOSS_SMASH) + 1)
	_check(near.hp == 100 - AbilityDefs.SMASH_DAMAGE, "smash: near player hit (got %d)" % near.hp)
	_check(far.hp == 100, "smash: far player untouched")
	_run(states, g, null, AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_SMASH] + AbilityDefs.RECOVERY_TICKS[AbilityDefs.BOSS_SMASH] + 1)
	_check(near.hp == 100 - AbilityDefs.SMASH_DAMAGE, "smash: applied exactly once")
	_check(boss.ability_cds[AbilityDefs.BOSS_SMASH] > 0, "smash: cooldown charged on the boss slot")
	# Boss HP survives the u16 wire roundtrip.
	var buf := PackedByteArray()
	boss.write_into(buf)
	var d := EntityState.read_from(Serialization.reader(buf))
	_check(d.hp == NetConfig.BOSS_MAX_HP and d.kind == NetConfig.KIND_BOSS, "boss: hp/kind wire roundtrip")

func _test_boss_charge() -> void:
	var g := _open_geometry()
	var boss := _entity(1, NetConfig.KIND_BOSS, Vector2(500, 500), NetConfig.BOSS_MAX_HP)
	boss.facing = Vector2.RIGHT
	# Damage resolves one move-tick before rest: boss at 500 + 17*14 = 738 px.
	var at_landing := _entity(2, NetConfig.KIND_PLAYER, Vector2(740, 500), 100)
	var at_start := _entity(3, NetConfig.KIND_PLAYER, Vector2(560, 500), 100)
	var states := {1: boss, 2: at_landing, 3: at_start}
	var total := AbilityDefs.WINDUP_TICKS[AbilityDefs.BOSS_CHARGE] + AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_CHARGE] + 2
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_BOSS_CHARGE), total)
	var expected := AbilityDefs.CHARGE_SPEED * NetConfig.DT * float(AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_CHARGE])
	_check(absf((boss.pos.x - 500.0) - expected) < 0.01,
		"charge: displacement %.1f expected %.1f" % [boss.pos.x - 500.0, expected])
	_check(at_landing.hp == 100 - AbilityDefs.CHARGE_DAMAGE, "charge: landing zone hit once (got %d)" % at_landing.hp)
	_check(at_start.hp == 100, "charge: start point NOT hit — dodge the landing, not the run-up")

func _test_boss_melee_reach() -> void:
	# A fat boss is hittable at range a monster is not: reach adds the TARGET radius.
	var g := _open_geometry()
	var atk := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	atk.facing = Vector2.RIGHT
	var boss := _entity(2, NetConfig.KIND_BOSS, Vector2(564, 500), NetConfig.BOSS_MAX_HP)  # dist 64 <= 30+8+28
	var states := {1: atk, 2: boss}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK), _ticks_to_active(AbilityDefs.MELEE) + 1)
	_check(boss.hp == NetConfig.BOSS_MAX_HP - AbilityDefs.MELEE_DAMAGE, "melee vs boss: edge reachable at 64 px")
	var atk2 := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	atk2.facing = Vector2.RIGHT
	var mon := _entity(2, NetConfig.KIND_MONSTER, Vector2(564, 500), 120)  # dist 64 > 30+8+8
	var states2 := {1: atk2, 2: mon}
	_run(states2, g, _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK), _ticks_to_active(AbilityDefs.MELEE) + 1)
	_check(mon.hp == 120, "melee vs monster: 64 px is out of reach (no regression)")

## The Lobby spawn hooks key off the first-ACTIVE-tick fingerprint; it must fire
## exactly once per cast for every server-spawning boss ability.
func _test_boss_spawn_edges() -> void:
	var g := _open_geometry()
	var cases := {
		AbilityDefs.BOSS_BARRAGE: NetConfig.BTN_BOSS_BARRAGE,
		AbilityDefs.BOSS_SUMMON: NetConfig.BTN_BOSS_SUMMON,
		AbilityDefs.BOSS_HAZARD: NetConfig.BTN_BOSS_HAZARD,
	}
	for aid in cases:
		var boss := _entity(1, NetConfig.KIND_BOSS, Vector2(500, 500), NetConfig.BOSS_MAX_HP)
		var states := {1: boss}
		var edges := 0
		for t in AbilityDefs.WINDUP_TICKS[aid] + AbilityDefs.ACTIVE_TICKS[aid] + 2:
			WorldSim.step(states, {1: _cmd(Vector2.ZERO, cases[aid])}, g, t, 0)
			if boss.ability_id == aid and boss.ability_phase == Ability.PHASE_ACTIVE \
			and boss.ability_timer == AbilityDefs.ACTIVE_TICKS[aid]:
				edges += 1
		_check(edges == 1, "spawn edge fires exactly once for ability %d (got %d)" % [aid, edges])

func _test_hazard_tick() -> void:
	var g := _open_geometry()
	var hz := _entity(9, NetConfig.KIND_HAZARD, Vector2(500, 500), 1)
	hz.ability_id = AbilityDefs.BOSS_HAZARD
	hz.ability_timer = AbilityDefs.HAZARD_TTL_TICKS
	hz.owner_id = 50
	var inside := _entity(1, NetConfig.KIND_PLAYER, Vector2(530, 500), 100)   # dist 30 <= 40+8
	var outside := _entity(2, NetConfig.KIND_PLAYER, Vector2(560, 500), 100)  # dist 60 > 48
	var mon := _entity(3, NetConfig.KIND_MONSTER, Vector2(500, 510), 120)     # inside, but players-only
	var states := {9: hz, 1: inside, 2: outside, 3: mon}
	for t in AbilityDefs.HAZARD_TTL_TICKS + 2:
		WorldSim.step(states, {}, g, t, 0)
	# Damage ticks at t = 0, 15, ..., 165 -> 12 hits of 8 while the zone lives.
	var hits := AbilityDefs.HAZARD_TTL_TICKS / AbilityDefs.HAZARD_TICK_INTERVAL
	_check(inside.hp == 100 - hits * AbilityDefs.HAZARD_DAMAGE,
		"hazard: %d periodic hits on the player inside (got hp %d)" % [hits, inside.hp])
	_check(outside.hp == 100, "hazard: player outside untouched")
	_check(mon.hp == 120, "hazard: monsters immune (players-only zones)")
	_check(hz.hp == 0, "hazard: dead after TTL")

func _test_bolt_over_hazard() -> void:
	# Hazards are hp-1 markers and must never absorb a projectile (is_targetable).
	var g := _open_geometry()
	var hz := _entity(9, NetConfig.KIND_HAZARD, Vector2(600, 500), 1)
	hz.ability_id = AbilityDefs.BOSS_HAZARD
	hz.ability_timer = AbilityDefs.HAZARD_TTL_TICKS
	var mon := _entity(2, NetConfig.KIND_MONSTER, Vector2(700, 500), 120)
	var bolt := _entity(5, NetConfig.KIND_PROJECTILE, Vector2(500, 500), 1)
	bolt.vel = Vector2.RIGHT * AbilityDefs.BOLT_SPEED
	bolt.ability_timer = AbilityDefs.BOLT_TTL_TICKS
	var states := {9: hz, 2: mon, 5: bolt}
	for t in AbilityDefs.BOLT_TTL_TICKS:
		if not bolt.is_alive():
			break
		WorldSim.step(states, {}, g, t, 0)
	_check(mon.hp == 120 - AbilityDefs.BOLT_DAMAGE, "bolt: flies over a hazard and still hits (got hp %d)" % mon.hp)

func _test_barrage_projectile() -> void:
	var g := _open_geometry()
	var minion := _entity(2, NetConfig.KIND_MONSTER, Vector2(540, 500), 120)
	minion.owner_id = 50                     # summoned by boss 50
	var player := _entity(3, NetConfig.KIND_PLAYER, Vector2(600, 500), 100)
	var shard := _entity(9, NetConfig.KIND_PROJECTILE, Vector2(500, 500), 1)
	shard.ability_id = AbilityDefs.BOSS_BARRAGE
	shard.owner_id = 50                      # same summoner: must skip the minion
	shard.vel = Vector2.RIGHT * AbilityDefs.BARRAGE_SPEED
	shard.ability_timer = AbilityDefs.BARRAGE_TTL_TICKS
	var states := {2: minion, 3: player, 9: shard}
	for t in AbilityDefs.BARRAGE_TTL_TICKS:
		if not shard.is_alive():
			break
		WorldSim.step(states, {}, g, t, 0)
	_check(minion.hp == 120, "barrage: skips the boss's own minions")
	_check(player.hp == 100 - AbilityDefs.BARRAGE_DAMAGE, "barrage: player hit for %d (got hp %d)"
		% [AbilityDefs.BARRAGE_DAMAGE, player.hp])
	_check(shard.hp == 0, "barrage: shard dies on hit")

# --- factions -----------------------------------------------------------------------
func _test_relation_packing() -> void:
	var rel := 0
	rel = FactionDefs.set_relation(rel, 1, 2, FactionDefs.REL_RIVAL)
	rel = FactionDefs.set_relation(rel, 3, 4, FactionDefs.REL_ALLIED)
	_check(FactionDefs.relation_of(1, 2, rel) == FactionDefs.REL_RIVAL, "relations: (1,2) rival")
	_check(FactionDefs.relation_of(2, 1, rel) == FactionDefs.REL_RIVAL, "relations: order-insensitive")
	_check(FactionDefs.relation_of(3, 4, rel) == FactionDefs.REL_ALLIED, "relations: (3,4) allied")
	_check(FactionDefs.relation_of(1, 3, rel) == FactionDefs.REL_NEUTRAL, "relations: untouched pair neutral")
	rel = FactionDefs.set_relation(rel, 1, 2, FactionDefs.REL_NEUTRAL)
	_check(FactionDefs.relation_of(1, 2, rel) == FactionDefs.REL_NEUTRAL \
		and FactionDefs.relation_of(3, 4, rel) == FactionDefs.REL_ALLIED,
		"relations: set_relation preserves other pairs")
	var seen := {}
	for a in range(1, FactionDefs.FACTION_COUNT + 1):
		for b in range(a + 1, FactionDefs.FACTION_COUNT + 1):
			seen[FactionDefs.pair_index(a, b)] = true
	_check(seen.size() == FactionDefs.PAIR_COUNT, "relations: 6 distinct pair indices")
	# Sanitize: the invalid 2-bit value 3 -> NEUTRAL; unused high bits zeroed.
	var dirty := 0x3 | (FactionDefs.REL_RIVAL << 2) | (0xF << 12)
	var clean := FactionDefs.sanitize_relations(dirty)
	_check(FactionDefs.relation_of(1, 2, clean) == FactionDefs.REL_NEUTRAL, "relations: invalid value sanitized")
	_check(FactionDefs.relation_of(1, 3, clean) == FactionDefs.REL_RIVAL, "relations: valid value kept")
	_check(clean < (1 << 12), "relations: unused high bits zeroed")
	_check(FactionDefs.sanitize_faction(4, 2) == 0 and FactionDefs.sanitize_faction(2, 2) == 2 \
		and FactionDefs.sanitize_faction(0, 4) == 0, "faction: sanitize_faction clamps to lobby count")

func _test_faction_melee_gating() -> void:
	var g := _open_geometry()
	# [attacker faction, target faction, relations, damage expected, label]
	var cases := [
		[1, 2, FactionDefs.RELATIONS_ALL_NEUTRAL, false, "neutral"],
		[1, 1, FactionDefs.RELATIONS_ALL_NEUTRAL, false, "same faction"],
		[1, 2, FactionDefs.set_relation(0, 1, 2, FactionDefs.REL_ALLIED), false, "allied"],
		[1, 2, FactionDefs.set_relation(0, 1, 2, FactionDefs.REL_RIVAL), true, "rival"],
	]
	for c in cases:
		var atk := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
		atk.facing = Vector2.RIGHT
		atk.faction = c[0]
		var tgt := _entity(2, NetConfig.KIND_PLAYER, Vector2(530, 500), 100)
		tgt.faction = c[1]
		var states := {1: atk, 2: tgt}
		_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK), _ticks_to_active(AbilityDefs.MELEE) + 1, c[2])
		var expected: int = (100 - AbilityDefs.MELEE_DAMAGE) if c[3] else 100
		_check(tgt.hp == expected, "melee gating: %s -> hp %d expected %d" % [c[4], tgt.hp, expected])
	# PvE regression: a factioned player still damages monsters under any table.
	var atk2 := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	atk2.facing = Vector2.RIGHT
	atk2.faction = 1
	var mon := _entity(2, NetConfig.KIND_MONSTER, Vector2(530, 500), 120)
	var states2 := {1: atk2, 2: mon}
	_run(states2, g, _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK), _ticks_to_active(AbilityDefs.MELEE) + 1,
		FactionDefs.set_relation(0, 1, 2, FactionDefs.REL_ALLIED))
	_check(mon.hp == 120 - AbilityDefs.MELEE_DAMAGE, "melee gating: monsters always hostile (PvE unchanged)")

func _test_faction_bolt_passthrough() -> void:
	# A bolt flies THROUGH a neutral player (no damage, no absorb) and still hits
	# the rival beyond — neutral bodies never shield rivals.
	var g := _open_geometry()
	var rel := FactionDefs.set_relation(0, 1, 3, FactionDefs.REL_RIVAL)
	var neutral := _entity(2, NetConfig.KIND_PLAYER, Vector2(600, 500), 100)
	neutral.faction = 2
	var rival := _entity(3, NetConfig.KIND_PLAYER, Vector2(700, 500), 100)
	rival.faction = 3
	var bolt := _entity(9, NetConfig.KIND_PROJECTILE, Vector2(500, 500), 1)
	bolt.ability_id = AbilityDefs.BOLT
	bolt.faction = 1
	bolt.owner_id = 42
	bolt.vel = Vector2.RIGHT * AbilityDefs.BOLT_SPEED
	bolt.ability_timer = AbilityDefs.BOLT_TTL_TICKS
	var states := {2: neutral, 3: rival, 9: bolt}
	for t in AbilityDefs.BOLT_TTL_TICKS:
		if not bolt.is_alive():
			break
		WorldSim.step(states, {}, g, t, rel)
	_check(neutral.hp == 100, "bolt factions: neutral player passed through")
	_check(rival.hp == 100 - AbilityDefs.BOLT_DAMAGE, "bolt factions: rival beyond is hit (got %d)" % rival.hp)
	_check(bolt.hp == 0, "bolt factions: dies on the rival hit")
	# A faction-0 shard (boss barrage) still hits every factioned player.
	var p1 := _entity(2, NetConfig.KIND_PLAYER, Vector2(600, 500), 100)
	p1.faction = 2
	var shard := _entity(9, NetConfig.KIND_PROJECTILE, Vector2(500, 500), 1)
	shard.ability_id = AbilityDefs.BOSS_BARRAGE
	shard.owner_id = 50
	shard.vel = Vector2.RIGHT * AbilityDefs.BARRAGE_SPEED
	shard.ability_timer = AbilityDefs.BARRAGE_TTL_TICKS
	var states2 := {2: p1, 9: shard}
	for t in AbilityDefs.BARRAGE_TTL_TICKS:
		if not shard.is_alive():
			break
		WorldSim.step(states2, {}, g, t, rel)
	_check(p1.hp == 100 - AbilityDefs.BARRAGE_DAMAGE, "bolt factions: faction-0 shard hits factioned players")

func _test_heal_splash() -> void:
	var g := _open_geometry()
	var rel := FactionDefs.set_relation(0, 1, 2, FactionDefs.REL_ALLIED)
	rel = FactionDefs.set_relation(rel, 1, 4, FactionDefs.REL_RIVAL)
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 50)
	caster.faction = 1
	var same := _entity(2, NetConfig.KIND_PLAYER, Vector2(540, 500), 50)
	same.faction = 1
	var ally := _entity(3, NetConfig.KIND_PLAYER, Vector2(460, 500), 50)
	ally.faction = 2
	var neutral := _entity(4, NetConfig.KIND_PLAYER, Vector2(500, 540), 50)
	neutral.faction = 3
	var rival := _entity(5, NetConfig.KIND_PLAYER, Vector2(500, 460), 50)
	rival.faction = 4
	var mon := _entity(6, NetConfig.KIND_MONSTER, Vector2(520, 520), 50)
	var far_ally := _entity(7, NetConfig.KIND_PLAYER, Vector2(900, 500), 50)
	far_ally.faction = 1
	var near_full := _entity(8, NetConfig.KIND_PLAYER, Vector2(480, 520), NetConfig.PLAYER_MAX_HP - 5)
	near_full.faction = 1
	var states := {1: caster, 2: same, 3: ally, 4: neutral, 5: rival, 6: mon, 7: far_ally, 8: near_full}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL), _ticks_to_active(AbilityDefs.HEAL) + 1, rel)
	_check(caster.hp == 50 + AbilityDefs.HEAL_AMOUNT, "heal splash: caster self-heals")
	_check(same.hp == 50 + AbilityDefs.HEAL_AMOUNT, "heal splash: same-faction healed")
	_check(ally.hp == 50 + AbilityDefs.HEAL_AMOUNT, "heal splash: allied faction healed")
	_check(neutral.hp == 50, "heal splash: neutral untouched")
	_check(rival.hp == 50, "heal splash: rival untouched")
	_check(mon.hp == 50, "heal splash: monsters untouched")
	_check(far_ally.hp == 50, "heal splash: out of radius untouched")
	_check(near_full.hp == NetConfig.PLAYER_MAX_HP, "heal splash: capped at max hp")

func _test_boss_vs_factions() -> void:
	# Boss abilities ignore player diplomacy entirely (faction 0 = hostile to all).
	var g := _open_geometry()
	var rel := FactionDefs.set_relation(0, 1, 2, FactionDefs.REL_ALLIED)
	var boss := _entity(1, NetConfig.KIND_BOSS, Vector2(500, 500), NetConfig.BOSS_MAX_HP)
	var p1 := _entity(2, NetConfig.KIND_PLAYER, Vector2(590, 500), 100)
	p1.faction = 1
	var p2 := _entity(3, NetConfig.KIND_PLAYER, Vector2(410, 500), 100)
	p2.faction = 2
	var states := {1: boss, 2: p1, 3: p2}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_BOSS_SMASH), _ticks_to_active(AbilityDefs.BOSS_SMASH) + 1, rel)
	_check(p1.hp == 100 - AbilityDefs.SMASH_DAMAGE and p2.hp == 100 - AbilityDefs.SMASH_DAMAGE,
		"boss vs factions: smash hits every faction regardless of relations")

# --- upgrades (gem economy) ------------------------------------------------------------
## Buy an item `n` times and return the packed value.
func _bought(upgrades: int, item_id: int, n: int = 1) -> int:
	for _i in n:
		upgrades = UpgradeDefs.apply_item(upgrades, item_id)
	return upgrades

func _test_upgrade_packing() -> void:
	var u := _bought(0, UpgradeDefs.ITEM_UP_MELEE, 3)
	_check(UpgradeDefs.skill_level(u, AbilityDefs.MELEE) == 3, "upgrades: 3 melee buys -> level 3")
	_check(UpgradeDefs.skill_level(u, AbilityDefs.BOLT) == 0, "upgrades: other skills untouched")
	_check(not UpgradeDefs.item_available(UpgradeDefs.ITEM_UP_MELEE, u), "upgrades: level 3 is maxed")
	_check(_bought(u, UpgradeDefs.ITEM_UP_MELEE) == u, "upgrades: buying past max is a no-op")
	_check(UpgradeDefs.item_cost(UpgradeDefs.ITEM_UP_BOLT, 0) == 5 \
		and UpgradeDefs.item_cost(UpgradeDefs.ITEM_UP_BOLT, _bought(0, UpgradeDefs.ITEM_UP_BOLT, 2)) == 15,
		"upgrades: level costs escalate 5/10/15")
	u = _bought(u, UpgradeDefs.ITEM_SKILL_NOVA)
	u = _bought(u, UpgradeDefs.ITEM_PASSIVE_FOCUS)
	_check(UpgradeDefs.has_skill(u, AbilityDefs.NOVA) and not UpgradeDefs.has_skill(u, AbilityDefs.VOLLEY),
		"upgrades: nova unlocked, volley still locked")
	_check(UpgradeDefs.has_passive(u, UpgradeDefs.BIT_FOCUS) and not UpgradeDefs.has_passive(u, UpgradeDefs.BIT_VIGOR),
		"upgrades: focus owned, vigor not")
	_check(not UpgradeDefs.item_available(UpgradeDefs.ITEM_SKILL_NOVA, u), "upgrades: owned unlock unavailable")
	_check(UpgradeDefs.has_skill(0, AbilityDefs.MELEE), "upgrades: base skills always owned")
	_check(u & ~UpgradeDefs.UPGRADES_MASK == 0, "upgrades: reserved bit stays clear")

func _test_upgrade_scaling() -> void:
	var g := _open_geometry()
	# Melee L3: 20 -> 29. Slam L3: 35 -> 50. Heal L3: 40 -> 58.
	var atk := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	atk.facing = Vector2.RIGHT
	atk.upgrades = _bought(0, UpgradeDefs.ITEM_UP_MELEE, 3)
	var tgt := _entity(2, NetConfig.KIND_MONSTER, Vector2(530, 500), 120)
	var states := {1: atk, 2: tgt}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK), _ticks_to_active(AbilityDefs.MELEE) + 1)
	_check(tgt.hp == 120 - 29, "upgrades: melee L3 deals 29 (got %d)" % (120 - tgt.hp))
	var slammer := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	slammer.upgrades = _bought(0, UpgradeDefs.ITEM_UP_SLAM, 3)
	var tgt2 := _entity(2, NetConfig.KIND_MONSTER, Vector2(540, 500), 120)
	var states2 := {1: slammer, 2: tgt2}
	_run(states2, g, _cmd(Vector2.ZERO, NetConfig.BTN_SLAM), _ticks_to_active(AbilityDefs.SLAM) + 1)
	_check(tgt2.hp == 120 - 50, "upgrades: slam L3 deals 50 (got %d)" % (120 - tgt2.hp))
	var healer := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 30)
	healer.upgrades = _bought(0, UpgradeDefs.ITEM_UP_HEAL, 3)
	var states3 := {1: healer}
	_run(states3, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL), _ticks_to_active(AbilityDefs.HEAL) + 1)
	_check(healer.hp == 30 + 58, "upgrades: heal L3 restores 58 (got hp %d)" % healer.hp)
	# VIGOR raises the heal cap to 125.
	var tank := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	tank.upgrades = _bought(_bought(0, UpgradeDefs.ITEM_UP_HEAL, 3), UpgradeDefs.ITEM_PASSIVE_VIGOR)
	var states4 := {1: tank}
	_run(states4, g, _cmd(Vector2.ZERO, NetConfig.BTN_HEAL), _ticks_to_active(AbilityDefs.HEAL) + 1)
	_check(tank.hp == NetConfig.PLAYER_MAX_HP + UpgradeDefs.VIGOR_BONUS_HP,
		"upgrades: vigor heal cap 125 (got %d)" % tank.hp)
	# Bolt L3: the caster's level rides the projectile -> 15 -> 21.
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	caster.facing = Vector2.RIGHT
	caster.upgrades = _bought(0, UpgradeDefs.ITEM_UP_BOLT, 3)
	var tgt3 := _entity(2, NetConfig.KIND_MONSTER, Vector2(700, 500), 120)
	var states5 := {1: caster, 2: tgt3}
	var bolt := _cast_bolt_and_spawn(states5, g)
	for t in AbilityDefs.BOLT_TTL_TICKS:
		if not bolt.is_alive():
			break
		WorldSim.step(states5, {}, g, t, 0)
	_check(tgt3.hp == 120 - 21, "upgrades: bolt L3 deals 21 (got %d)" % (120 - tgt3.hp))
	# Dash L3 cooldown 60 -> 33; with FOCUS -> 29. (Cooldown writes on cast end.)
	_check(UpgradeDefs.cooldown_for(AbilityDefs.DASH, _bought(0, UpgradeDefs.ITEM_UP_DASH, 3)) == 33,
		"upgrades: dash L3 cooldown 33")
	_check(UpgradeDefs.cooldown_for(AbilityDefs.DASH,
		_bought(_bought(0, UpgradeDefs.ITEM_UP_DASH, 3), UpgradeDefs.ITEM_PASSIVE_FOCUS)) == 29,
		"upgrades: dash L3 + focus cooldown 29")
	_check(UpgradeDefs.cooldown_for(AbilityDefs.BOSS_SUMMON, UpgradeDefs.BIT_FOCUS) == 255,
		"upgrades: focus never touches boss abilities")
	var dasher := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	dasher.facing = Vector2.RIGHT
	dasher.upgrades = _bought(0, UpgradeDefs.ITEM_UP_DASH, 3)
	var states6 := {1: dasher}
	_run(states6, g, _cmd(Vector2.ZERO, NetConfig.BTN_DASH),
		1 + AbilityDefs.ACTIVE_TICKS[AbilityDefs.DASH] + AbilityDefs.RECOVERY_TICKS[AbilityDefs.DASH] + 1)
	_check(dasher.ability_cds[AbilityDefs.DASH] > 0 and dasher.ability_cds[AbilityDefs.DASH] <= 33,
		"upgrades: dash L3 charges the reduced cooldown (got %d)" % dasher.ability_cds[AbilityDefs.DASH])

func _test_swift_speed() -> void:
	var g := _open_geometry()
	var swift := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	swift.upgrades = _bought(0, UpgradeDefs.ITEM_PASSIVE_SWIFT)
	var states := {1: swift}
	_run(states, g, _cmd(Vector2.RIGHT, 0), 1)
	var expected := NetConfig.PLAYER_SPEED * UpgradeDefs.SWIFT_SPEED_MULT * NetConfig.DT
	_check(absf((swift.pos.x - 500.0) - expected) < 0.01,
		"upgrades: swift step %.3f expected %.3f" % [swift.pos.x - 500.0, expected])

func _test_nova() -> void:
	var g := _open_geometry()
	# Locked: the ladder ignores the press on both ends (no cast, no error).
	var locked := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	var states0 := {1: locked}
	_run(states0, g, _cmd(Vector2.ZERO, NetConfig.BTN_NOVA), 3)
	_check(locked.ability_phase == Ability.PHASE_IDLE, "nova: locked press is ignored")
	# Unlocked: PBAoE hits inside NOVA_RADIUS + target radius, misses beyond.
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	caster.upgrades = _bought(0, UpgradeDefs.ITEM_SKILL_NOVA)
	var near := _entity(2, NetConfig.KIND_MONSTER, Vector2(610, 500), 120)   # dist 110 <= 110+8
	var far := _entity(3, NetConfig.KIND_MONSTER, Vector2(630, 500), 120)    # dist 130 > 118
	var states := {1: caster, 2: near, 3: far}
	_run(states, g, _cmd(Vector2.ZERO, NetConfig.BTN_NOVA), _ticks_to_active(AbilityDefs.NOVA) + 1)
	_check(near.hp == 120 - AbilityDefs.NOVA_DAMAGE, "nova: near target hit for %d (got hp %d)"
		% [AbilityDefs.NOVA_DAMAGE, near.hp])
	_check(far.hp == 120, "nova: far target untouched")
	_run(states, g, null, AbilityDefs.ACTIVE_TICKS[AbilityDefs.NOVA] + AbilityDefs.RECOVERY_TICKS[AbilityDefs.NOVA] + 1)
	_check(near.hp == 120 - AbilityDefs.NOVA_DAMAGE, "nova: applied exactly once")
	_check(caster.ability_cds[AbilityDefs.NOVA] > 0, "nova: cooldown charged on its own slot")

## Mirror Lobby's VOLLEY spawn recipe (3 shards, +/-15 degrees) and fly them.
func _test_volley() -> void:
	var g := _open_geometry()
	var caster := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	caster.facing = Vector2.RIGHT
	caster.upgrades = _bought(0, UpgradeDefs.ITEM_SKILL_VOLLEY)
	var tgt := _entity(2, NetConfig.KIND_MONSTER, Vector2(700, 500), 120)
	var states := {1: caster, 2: tgt}
	# Drive through the cast; assert the first-ACTIVE-tick spawn edge fires once.
	var edges := 0
	var shards: Array = []
	for t in AbilityDefs.WINDUP_TICKS[AbilityDefs.VOLLEY] + AbilityDefs.ACTIVE_TICKS[AbilityDefs.VOLLEY] + 2:
		WorldSim.step(states, {1: _cmd(Vector2.ZERO, NetConfig.BTN_VOLLEY)}, g, t, 0)
		if caster.ability_id == AbilityDefs.VOLLEY and caster.ability_phase == Ability.PHASE_ACTIVE \
		and caster.ability_timer == AbilityDefs.ACTIVE_TICKS[AbilityDefs.VOLLEY]:
			edges += 1
			if shards.is_empty():
				for k in AbilityDefs.VOLLEY_COUNT:
					var ang := deg_to_rad(AbilityDefs.VOLLEY_SPREAD_DEGREES) * float(k - 1)
					var dir := caster.facing.rotated(ang)
					var b := EntityState.new()
					b.id = 90 + k
					b.kind = NetConfig.KIND_PROJECTILE
					b.hp = 1
					b.owner_id = caster.id
					b.ability_id = AbilityDefs.VOLLEY
					b.upgrades = caster.upgrades
					b.facing = dir
					b.vel = dir * AbilityDefs.VOLLEY_SPEED
					b.pos = caster.pos + dir * (NetConfig.ENTITY_RADIUS + AbilityDefs.BOLT_RADIUS + AbilityDefs.BOLT_SPAWN_GAP)
					b.ability_timer = AbilityDefs.VOLLEY_TTL_TICKS
					shards.append(b)
	_check(edges == 1, "volley: spawn edge fires exactly once (got %d)" % edges)
	_check(shards.size() == AbilityDefs.VOLLEY_COUNT, "volley: 3 shards spawned")
	for b in shards:
		states[b.id] = b
	for t in AbilityDefs.VOLLEY_TTL_TICKS:
		WorldSim.step(states, {}, g, t, 0)
	# Only the center shard's ray crosses the target: exactly one 12-damage hit.
	_check(tgt.hp == 120 - AbilityDefs.VOLLEY_DAMAGE, "volley: center shard hits for %d (got hp %d)"
		% [AbilityDefs.VOLLEY_DAMAGE, tgt.hp])
	var dead := 0
	for b in shards:
		if b.hp == 0:
			dead += 1
	_check(dead >= 1, "volley: the hitting shard died")

## The reconciliation contract again, now with sim-read upgrades in play.
func _test_upgrade_replay_determinism() -> void:
	var g := _open_geometry()
	var a := _entity(1, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	a.facing = Vector2.RIGHT
	a.upgrades = _bought(_bought(_bought(0, UpgradeDefs.ITEM_UP_DASH, 3),
		UpgradeDefs.ITEM_PASSIVE_SWIFT), UpgradeDefs.ITEM_SKILL_NOVA)
	var b := a.clone()
	var cmds: Array = []
	for t in 40:
		var buttons := 0
		if t < 2:
			buttons = NetConfig.BTN_DASH
		elif t == 12:
			buttons = NetConfig.BTN_NOVA
		cmds.append(_cmd(Vector2.DOWN if t > 20 else Vector2.ZERO, buttons))
	for c in cmds:
		WorldSim.step({1: a}, {1: c}, g, 0, 0)
	for c in cmds:
		WorldSim.step({1: b}, {1: c}, g, 0, 0)
	var ba := PackedByteArray()
	var bb := PackedByteArray()
	a.write_into(ba)
	b.write_into(bb)
	_check(ba == bb, "upgrade replay: byte-identical after identical inputs from a clone")

func _test_last_hit_credit() -> void:
	var g := _open_geometry()
	# Direct hit credits the attacker's entity id.
	var atk := _entity(4, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	atk.facing = Vector2.RIGHT
	var tgt := _entity(2, NetConfig.KIND_MONSTER, Vector2(530, 500), 120)
	var states := {4: atk, 2: tgt}
	for t in _ticks_to_active(AbilityDefs.MELEE) + 1:
		WorldSim.step(states, {4: _cmd(Vector2.ZERO, NetConfig.BTN_ATTACK)}, g, t, 0)
	_check(tgt.last_hit_by == 4, "credit: melee stamps the attacker id (got %d)" % tgt.last_hit_by)
	# Projectile hit credits the CASTER (owner_id), not the projectile.
	var caster := _entity(6, NetConfig.KIND_PLAYER, Vector2(500, 500), 100)
	caster.facing = Vector2.RIGHT
	var tgt2 := _entity(2, NetConfig.KIND_MONSTER, Vector2(700, 500), 120)
	var bolt := _entity(9, NetConfig.KIND_PROJECTILE, Vector2(520, 500), 1)
	bolt.ability_id = AbilityDefs.BOLT
	bolt.owner_id = caster.id
	bolt.vel = Vector2.RIGHT * AbilityDefs.BOLT_SPEED
	bolt.ability_timer = AbilityDefs.BOLT_TTL_TICKS
	var states2 := {6: caster, 2: tgt2, 9: bolt}
	for t in AbilityDefs.BOLT_TTL_TICKS:
		if not bolt.is_alive():
			break
		WorldSim.step(states2, {}, g, t, 0)
	_check(tgt2.last_hit_by == 6, "credit: bolt stamps the caster id (got %d)" % tgt2.last_hit_by)
