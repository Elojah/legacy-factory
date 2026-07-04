extends SceneTree
## Headless server-side raid-boss exercise. Builds a real Lobby (MEDIUM => 3
## boss islands; the scenario drives the CENTER apex boss) and runs step_sim end
## to end: aggro + pattern casting across all three hp phases, summon/hazard
## spawning, boss damage output, death cleanup (minions die with the boss and
## never respawn), the long respawn timer, the at-home raid reset, tiered gem
## awards, faction corner spawns and monster home respawns. Run with:
##   godot-4 --headless --path . --script res://tools/test_boss_sim.gd
##
## lobby.gd is loaded at RUNTIME (untyped), not referenced by class_name: under
## --script the analyzer can resolve autoload CONSTANTS (NetConfig.X) but not
## autoload instance calls (NetManager.foo()), so any script in this tool's
## compile-time graph must avoid them — and Lobby sends despawns via NetManager.

var _fails: int = 0
var _checks: int = 0

func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL %s" % label)

func _initialize() -> void:
	# Cover all 3 kits: find a MEDIUM seed whose CENTER (apex) boss rolls each
	# kit and run the full raid scenario once per kit.
	var seed_for_kit := {}
	var probe := 1
	while seed_for_kit.size() < BossDefs.KIT_COUNT and probe < 200:
		var g := WorldGenerator.generate(probe, WorldGenerator.SIZE_MEDIUM)
		if g.boss_kits.size() == 3:
			var kit: int = g.boss_kits[_apex_index(g)]
			if not seed_for_kit.has(kit):
				seed_for_kit[kit] = probe
		probe += 1
	_check(seed_for_kit.size() == BossDefs.KIT_COUNT, "found a seed for every kit")
	for kit in seed_for_kit:
		_run_scenario(int(seed_for_kit[kit]))
	_test_diplomacy()
	_test_gems()
	_test_spawns()
	_test_pickups()
	_test_teleport()
	_test_shrines()
	_finish()

## Index (into the boss_* parallel arrays) of the apex boss: the highest tier —
## always the center island (the only tier-MAX_TIER boss).
func _apex_index(g: WorldGeometry) -> int:
	var best := 0
	for j in g.boss_tiers.size():
		if int(g.boss_tiers[j]) > int(g.boss_tiers[best]):
			best = j
	return best

func _run_scenario(map_seed: int) -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(1, "bosstest", 0, WorldGenerator.SIZE_MEDIUM, 2, map_seed)
	_check(lobby.geometry.boss_spawns.size() == 3, "medium lobby generates three boss islands")

	# The scenario drives the CENTER apex boss (tier 3, full raid hp); the outer
	# bosses idle on their distant islands throughout.
	var j := _apex_index(lobby.geometry)
	var spawn: Vector2 = lobby.geometry.boss_spawns[j]
	var boss: EntityState = null
	for eid in lobby._states:
		var st: EntityState = lobby._states[eid]
		if st.kind == NetConfig.KIND_BOSS and st.pos.distance_to(spawn) < 1.0:
			boss = st
	_check(boss != null and boss.hp == NetConfig.BOSS_MAX_HP,
		"apex boss spawned at full raid hp (tier 3)")
	if boss == null:
		_finish()
		return
	var bmax := EntityDefs.max_hp_of(boss)
	var home := boss.pos
	var kit: int = lobby.geometry.boss_kits[j]
	print("  seed %d -> apex kit = %s" % [map_seed, BossDefs.kit_name(kit)])

	# A raid dummy standing at a FIXED spot near the arena (hp far above the u16
	# cap is fine in-sim). The boss closes/opens distance itself: the AI walks in
	# for a pending smash and backs away for a pending charge, so every range
	# gate gets satisfied without the test steering anything.
	var player := EntityState.new()
	player.id = lobby._alloc_id()
	player.kind = NetConfig.KIND_PLAYER
	player.hp = 60000
	player.pos = home + Vector2(150, 0)
	lobby._states[player.id] = player

	# Drive 3 combat windows, forcing the boss into each hp phase; record which
	# abilities it casts and which transients appear.
	var cast_ids := {}
	var saw_hazard := false
	var saw_minion := false
	var tick := 0
	for phase_hp in [1.0, 0.5, 0.2]:
		boss.hp = int(float(bmax) * float(phase_hp))
		player.pos = home + Vector2(150, 0)
		for _t in 700:
			lobby.step_sim(tick)
			tick += 1
			if boss.ability_phase != Ability.PHASE_IDLE:
				cast_ids[boss.ability_id] = true
			for eid in lobby._states:
				var s: EntityState = lobby._states[eid]
				if s.kind == NetConfig.KIND_HAZARD:
					saw_hazard = true
				elif s.kind == NetConfig.KIND_MONSTER and s.owner_id == boss.id and s.is_alive():
					saw_minion = true
			if player.hp < 30000:
				player.hp = 60000

	# The boss must have played its whole kit across the three phases.
	var expected := {}
	for phase in BossDefs.PHASE_COUNT:
		for btn in BossDefs.pattern(kit, phase):
			expected[BossDefs.ability_for_button(btn)] = true
	for aid in expected:
		_check(cast_ids.has(aid), "kit ability %d was cast across the phases" % aid)
	_check(saw_hazard == expected.has(AbilityDefs.BOSS_HAZARD), "hazard zones spawned iff the kit drops them")
	_check(saw_minion == expected.has(AbilityDefs.BOSS_SUMMON), "minions summoned iff the kit summons")
	_check(player.hp < 60000, "the raid dummy took boss damage")

	# --- death: cleanup + the long timer -----------------------------------------
	boss.hp = 0
	lobby.step_sim(tick); tick += 1
	_check(int(lobby._respawn_timers.get(boss.id, -1)) == BossDefs.BOSS_RESPAWN_TICKS - 1 \
		or int(lobby._respawn_timers.get(boss.id, -1)) == BossDefs.BOSS_RESPAWN_TICKS,
		"boss death arms the %d-tick respawn timer" % BossDefs.BOSS_RESPAWN_TICKS)
	var live_minions := 0
	for eid in lobby._states:
		var s: EntityState = lobby._states[eid]
		if s.kind == NetConfig.KIND_MONSTER and s.owner_id == boss.id and s.is_alive():
			live_minions += 1
	_check(live_minions == 0, "boss death kills its live minions")
	# Corpse-linger then despawn — and they must never respawn.
	for _t in BossDefs.MINION_REAP_TICKS + 5:
		lobby.step_sim(tick); tick += 1
	var minions_left := 0
	var hazards_left := 0
	for eid in lobby._states:
		var s: EntityState = lobby._states[eid]
		if s.kind == NetConfig.KIND_MONSTER and s.owner_id == boss.id:
			minions_left += 1
		elif s.kind == NetConfig.KIND_HAZARD:
			hazards_left += 1
	_check(minions_left == 0, "minions reaped, never respawned (left %d)" % minions_left)
	_check(hazards_left == 0, "hazards reaped after the boss died (left %d)" % hazards_left)
	_check(boss.hp == 0, "boss still dead while the long timer runs")

	# --- respawn at home ----------------------------------------------------------
	lobby._respawn_timers[boss.id] = 1
	lobby.step_sim(tick); tick += 1
	_check(boss.hp == bmax, "boss respawns at full (tiered) hp")
	_check(boss.pos.distance_to(home) < 1.0, "boss respawns at home")

	# --- raid reset ----------------------------------------------------------------
	player.pos = home + Vector2(5000, 0)  # everyone leaves
	@warning_ignore("integer_division")
	boss.hp = bmax / 3
	for _t in 10:
		lobby.step_sim(tick); tick += 1
	_check(boss.hp == bmax, "at home + out of combat => full raid reset")

## Drive Lobby.apply_diplomacy through the rules table with two spawned players
## (faction 1 and 2 in a 3-faction lobby). `active` is cleared after spawning so
## the event broadcast targets nobody — under --script the NetManager autoload
## is not in the tree yet and any rpc_id would error noisily.
func _test_diplomacy() -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(2, "diplo", 0, WorldGenerator.SIZE_SMALL, 3, 1)
	lobby.add_member(10)
	lobby.add_member(11)
	lobby.spawn_player(10, 0, 1)
	lobby.spawn_player(11, 0, 2)
	lobby.active.clear()
	var t := 0
	_check(int(lobby.relations) == FactionDefs.RELATIONS_ALL_NEUTRAL, "diplo: starts all-neutral")
	# Auto-assign: an invalid pick (faction 4 in a 3-faction lobby) balances to
	# the least-populated faction (3 here, since 1 and 2 hold one player each).
	_check(int(lobby.assign_faction(4)) == 3, "diplo: invalid pick auto-assigned to least populated")
	_check(int(lobby.assign_faction(2)) == 2, "diplo: valid pick honored")
	# Unilateral rivalry.
	lobby.apply_diplomacy(10, 2, FactionDefs.DIPLO_DECLARE_RIVALRY, t)
	_check(FactionDefs.relation_of(1, 2, int(lobby.relations)) == FactionDefs.REL_RIVAL, "diplo: rivalry declared")
	# One-sided proposal changes nothing yet; the mutual proposal forms the
	# alliance (this is also the peace path out of rivalry).
	lobby.apply_diplomacy(10, 2, FactionDefs.DIPLO_PROPOSE_ALLIANCE, t)
	_check(FactionDefs.relation_of(1, 2, int(lobby.relations)) == FactionDefs.REL_RIVAL, "diplo: single proposal pends")
	lobby.apply_diplomacy(11, 1, FactionDefs.DIPLO_PROPOSE_ALLIANCE, t)
	_check(FactionDefs.relation_of(1, 2, int(lobby.relations)) == FactionDefs.REL_ALLIED, "diplo: mutual proposals ally")
	# Breaking is unilateral, back to neutral.
	lobby.apply_diplomacy(11, 1, FactionDefs.DIPLO_BREAK_ALLIANCE, t)
	_check(FactionDefs.relation_of(1, 2, int(lobby.relations)) == FactionDefs.REL_NEUTRAL, "diplo: alliance broken to neutral")
	# Betrayal: allied -> rival directly.
	lobby.apply_diplomacy(10, 2, FactionDefs.DIPLO_PROPOSE_ALLIANCE, t)
	lobby.apply_diplomacy(11, 1, FactionDefs.DIPLO_PROPOSE_ALLIANCE, t)
	lobby.apply_diplomacy(10, 2, FactionDefs.DIPLO_DECLARE_RIVALRY, t)
	_check(FactionDefs.relation_of(1, 2, int(lobby.relations)) == FactionDefs.REL_RIVAL, "diplo: betrayal allied -> rival")
	# Garbage is rejected: self-target, out-of-range faction, unknown peer.
	var before: int = lobby.relations
	lobby.apply_diplomacy(10, 1, FactionDefs.DIPLO_DECLARE_RIVALRY, t)
	lobby.apply_diplomacy(10, 4, FactionDefs.DIPLO_DECLARE_RIVALRY, t)
	lobby.apply_diplomacy(99, 2, FactionDefs.DIPLO_DECLARE_RIVALRY, t)
	_check(int(lobby.relations) == before, "diplo: self/out-of-range/unknown-peer requests rejected")

## Boss kills pay gems to the last-hitter's whole faction; village merchants
## sell upgrades through Lobby.apply_purchase. Runs on a real MEDIUM lobby
## (one boss + merchants). `active` is cleared after spawning so the gated
## _send_gems/despawn sends never reach the absent NetManager autoload — the
## same trick as _test_diplomacy; the gems/upgrades mutations stay assertable.
func _test_gems() -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(3, "gems", 0, WorldGenerator.SIZE_MEDIUM, 2, 1)
	_disable_pickups(lobby)   # exact-gems assertions below; a spawn-adjacent orb must not pollute them
	lobby.add_member(10)
	lobby.add_member(11)
	lobby.add_member(12)
	lobby.spawn_player(10, 0, 1)
	lobby.spawn_player(11, 0, 1)   # same faction as the killer
	lobby.spawn_player(12, 0, 2)   # other faction: no payout
	lobby.active.clear()
	# The apex (center, tier 3) boss: its tiered award is the table's top entry.
	var j := _apex_index(lobby.geometry)
	var spawn: Vector2 = lobby.geometry.boss_spawns[j]
	var boss: EntityState = null
	for eid in lobby._states:
		var st: EntityState = lobby._states[eid]
		if st.kind == NetConfig.KIND_BOSS and st.pos.distance_to(spawn) < 1.0:
			boss = st
	_check(boss != null, "gems: medium lobby has an apex boss")
	if boss == null:
		return
	var award := UpgradeDefs.boss_award_for(boss.upgrades)
	_check(award == UpgradeDefs.GEM_AWARD_BOSS_BY_TIER[3], "gems: apex boss pays the tier-3 award")
	var t := 0
	# Last hit by peer 10's entity -> faction 1 (peers 10 + 11) paid, peer 12 not.
	boss.last_hit_by = int(lobby._players[10].entity_id)
	boss.hp = 0
	lobby.step_sim(t); t += 1
	_check(int(lobby._players[10].gems) == award, "gems: killer paid")
	_check(int(lobby._players[11].gems) == award, "gems: faction mate paid")
	_check(int(lobby._players[12].gems) == 0, "gems: other faction not paid")
	# The award fires once per death (the respawn-timer guard), not every tick.
	lobby.step_sim(t); t += 1
	_check(int(lobby._players[10].gems) == award, "gems: paid exactly once")
	# Revive clears the credit; a kill credited to a vanished entity pays nobody.
	lobby._respawn_timers[boss.id] = 1
	lobby.step_sim(t); t += 1
	_check(boss.hp == EntityDefs.max_hp_of(boss) and int(boss.last_hit_by) == 0, "gems: revive clears kill credit")
	boss.last_hit_by = 999999
	boss.hp = 0
	lobby.step_sim(t); t += 1
	_check(int(lobby._players[10].gems) == award, "gems: vanished killer pays nobody")

	# --- apply_purchase validation matrix ------------------------------------------
	var sp = lobby._players[10]
	var s: EntityState = lobby._states[sp.entity_id]
	sp.gems = 100
	s.hp = 100  # monsters may have nicked the idle spawn during the steps above
	s.pos = lobby.geometry.merchants[0]
	lobby.apply_purchase(10, UpgradeDefs.ITEM_UP_MELEE)
	_check(UpgradeDefs.skill_level(int(s.upgrades), AbilityDefs.MELEE) == 1 and int(sp.gems) == 95,
		"purchase: melee level 1 for 5 gems")
	lobby.apply_purchase(10, UpgradeDefs.ITEM_UP_MELEE)   # 10 more
	lobby.apply_purchase(10, UpgradeDefs.ITEM_UP_MELEE)   # 15 more
	_check(UpgradeDefs.skill_level(int(s.upgrades), AbilityDefs.MELEE) == 3 and int(sp.gems) == 70,
		"purchase: melee maxed for 5+10+15")
	lobby.apply_purchase(10, UpgradeDefs.ITEM_UP_MELEE)
	_check(int(sp.gems) == 70, "purchase: maxed item rejected, gems unchanged")
	lobby.apply_purchase(10, UpgradeDefs.ITEM_SKILL_NOVA)
	_check(UpgradeDefs.has_skill(int(s.upgrades), AbilityDefs.NOVA) and int(sp.gems) == 45,
		"purchase: nova unlocked for 25")
	lobby.apply_purchase(10, 99)
	_check(int(sp.gems) == 45, "purchase: invalid item id rejected")
	sp.gems = 3
	lobby.apply_purchase(10, UpgradeDefs.ITEM_PASSIVE_VIGOR)
	_check(int(sp.gems) == 3 and not UpgradeDefs.has_passive(int(s.upgrades), UpgradeDefs.BIT_VIGOR),
		"purchase: insufficient funds rejected")
	sp.gems = 100
	# Out of range: walk past MERCHANT_RANGE (other merchants are islands away).
	s.pos = lobby.geometry.merchants[0] + Vector2(UpgradeDefs.MERCHANT_RANGE + 50.0, 0)
	lobby.apply_purchase(10, UpgradeDefs.ITEM_PASSIVE_VIGOR)
	_check(int(sp.gems) == 100, "purchase: out of merchant range rejected")
	s.pos = lobby.geometry.merchants[0]
	s.hp = 0
	lobby.apply_purchase(10, UpgradeDefs.ITEM_PASSIVE_VIGOR)
	_check(int(sp.gems) == 100, "purchase: dead player rejected")
	lobby.apply_purchase(99, UpgradeDefs.ITEM_PASSIVE_VIGOR)
	_check(int(sp.gems) == 100, "purchase: unknown peer ignored")

## Corner faction spawns + monster kill gems + monster home respawn, on a real
## 4-faction MEDIUM lobby (`active` cleared — same NetManager trick as above).
func _test_spawns() -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(4, "spawns", 0, WorldGenerator.SIZE_MEDIUM, 4, 7)
	_disable_pickups(lobby)   # exact-gems assertions below (monster kill payouts)
	for k in 4:
		lobby.add_member(20 + k)
		lobby.spawn_player(20 + k, 0, k + 1)
	lobby.active.clear()
	var g: WorldGeometry = lobby.geometry
	# Each faction spawns on a village tagged with ITS faction (its corner island).
	for k in 4:
		var s: EntityState = lobby._states[lobby._players[20 + k].entity_id]
		var vi := -1
		for i in g.villages.size():
			if g.villages[i].distance_to(s.pos) < 0.5:
				vi = i
				break
		_check(vi != -1 and int(g.village_factions[vi]) == k + 1,
			"spawn: faction %d lands on its own corner village" % (k + 1))

	# A world monster: tiered hp, pays (tier+1) gems to its last-hitter once,
	# and respawns at its OWN home point (not another island's spawn).
	var mon: EntityState = null
	var ids: Array = lobby._states.keys()
	ids.sort()
	for eid in ids:
		var s2: EntityState = lobby._states[eid]
		if s2.kind == NetConfig.KIND_MONSTER and s2.owner_id == 0:
			mon = s2
			break
	_check(mon != null, "spawn: medium lobby has world monsters")
	if mon == null:
		return
	_check(mon.hp == EntityDefs.max_hp_of(mon), "spawn: monster hp follows its tier")
	var mon_home: Vector2 = mon.pos
	var mon_award := UpgradeDefs.monster_award_for(mon.upgrades)
	var killer_sp = lobby._players[20]
	var t := 1000
	mon.last_hit_by = int(killer_sp.entity_id)
	mon.hp = 0
	lobby.step_sim(t); t += 1
	_check(int(killer_sp.gems) == mon_award, "gems: monster kill pays (tier+1) to the last-hitter")
	lobby.step_sim(t); t += 1
	_check(int(killer_sp.gems) == mon_award, "gems: monster kill paid exactly once")
	# Drag the corpse elsewhere, then let the timer expire: it must come home.
	mon.pos = mon_home + Vector2(300, 0)
	for _t in 95:
		lobby.step_sim(t); t += 1
	_check(mon.is_alive() and mon.pos.distance_to(mon_home) < 0.5,
		"respawn: monster returns to its own home point")
	_check(mon.hp == EntityDefs.max_hp_of(mon), "respawn: monster refills to its tiered max")

## Empty a lobby's pickup arrays so tests with exact-gems assertions can never
## be polluted by a seed-dependent orb sitting next to a spawn village. The
## arrays are the lobby's own geometry instance — test-local mutation.
func _disable_pickups(lobby) -> void:
	lobby.geometry.resources.clear()
	lobby.geometry.resource_tiers.clear()
	lobby.geometry.caches.clear()
	lobby.geometry.cache_tiers.clear()

## Walk-over orb/cache pickups: tier-scaled award paid once, taken -> respawn
## cycle, dead players collect nothing (real MEDIUM lobby, `active` cleared —
## the usual NetManager trick).
func _test_pickups() -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(5, "pickups", 0, WorldGenerator.SIZE_MEDIUM, 2, 1)
	lobby.add_member(50)
	lobby.spawn_player(50, 0, 1)
	lobby.active.clear()
	var g: WorldGeometry = lobby.geometry
	var sp = lobby._players[50]
	var s: EntityState = lobby._states[sp.entity_id]
	s.hp = 60000  # raid-dummy trick: the test orb sits on the apex boss island
	# Reduce to ONE known orb (the center boss island always keeps tier-3 orbs on
	# MEDIUM) so adjacent-tile double-pickups can't blur the exact assertions.
	var oi := -1
	for i in g.resource_tiers.size():
		if int(g.resource_tiers[i]) == 3:
			oi = i
			break
	_check(oi != -1, "pickups: a tier-3 orb exists on MEDIUM")
	if oi == -1:
		return
	var opos: Vector2 = g.resources[oi]
	_disable_pickups(lobby)
	g.resources.append(opos)
	g.resource_tiers.append(3)
	var award: int = UpgradeDefs.GEM_AWARD_ORB_BY_TIER[3]
	var t := 0
	s.pos = opos
	lobby.step_sim(t); t += 1
	_check(int(sp.gems) == award and lobby._orbs_taken.has(0), "pickups: orb pays its tier award once taken")
	lobby.step_sim(t); t += 1
	_check(int(sp.gems) == award, "pickups: taken orb pays exactly once")
	# Respawn: the pass frees it, then the same tick's pickup pass re-claims it.
	lobby._orbs_taken[0] = t
	lobby.step_sim(t); t += 1
	_check(int(sp.gems) == 2 * award and lobby._orbs_taken.has(0), "pickups: respawned orb is collectable again")
	# A dead player collects nothing (the orb respawns but stays on the ground).
	s.hp = 0
	lobby._orbs_taken[0] = t
	lobby.step_sim(t); t += 1
	_check(int(sp.gems) == 2 * award and not lobby._orbs_taken.has(0), "pickups: dead player collects nothing")
	s.hp = 60000
	lobby._respawn_timers.erase(sp.entity_id)
	# Cache: pays from the cache table (park the orb far in the future first).
	lobby._orbs_taken[0] = t + 1000000
	g.caches.append(s.pos)
	g.cache_tiers.append(3)
	var cache_award: int = UpgradeDefs.GEM_AWARD_CACHE_BY_TIER[3]
	lobby.step_sim(t); t += 1
	_check(int(sp.gems) == 2 * award + cache_award and lobby._caches_taken.has(0),
		"pickups: cache pays from the cache table")

## Waypoint teleport: the apply_teleport validation matrix, cancel-on-move,
## cancel-on-damage, completion (pos snap + cooldown stamp), cooldown gate.
func _test_teleport() -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(6, "teleport", 0, WorldGenerator.SIZE_MEDIUM, 2, 1)
	lobby.add_member(30)
	lobby.spawn_player(30, 0, 1)
	lobby.active.clear()
	var g: WorldGeometry = lobby.geometry
	var sp = lobby._players[30]
	var s: EntityState = lobby._states[sp.entity_id]
	var village_pos: Vector2 = s.pos   # faction-1 corner village = a waypoint anchor
	var t := 0
	# Destination: a neutral mid merchant (index >= 4) — a real cross-map move.
	var dest_idx := 4
	_check(g.merchants.size() > 4 and g.merchant_faction(dest_idx) == 0, "tp: mid merchant exists and is neutral")
	# Validation matrix — each rejected request must leave no channel.
	lobby.apply_teleport(99, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.is_empty(), "tp: unknown peer ignored")
	s.hp = 0
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.is_empty(), "tp: dead player rejected")
	s.hp = 100
	s.pos = g.boss_spawns[0]   # boss islands hold no waypoints: out of range
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.is_empty(), "tp: far from any waypoint rejected")
	s.pos = village_pos
	var enemy_vi := -1
	for i in g.village_factions.size():
		if int(g.village_factions[i]) != 1:
			enemy_vi = i
			break
	lobby.apply_teleport(30, TeleportDefs.DEST_VILLAGE, enemy_vi, t)
	_check(lobby._teleports.is_empty(), "tp: enemy village denied")
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, 0, t)
	_check(lobby._teleports.is_empty(), "tp: corner merchant denied (redundant with the village)")
	lobby.apply_teleport(30, TeleportDefs.DEST_VILLAGE, 999, t)
	lobby.apply_teleport(30, TeleportDefs.DEST_VILLAGE, -1, t)
	lobby.apply_teleport(30, 99, 0, t)
	_check(lobby._teleports.is_empty(), "tp: bad kind/index rejected")
	# Valid start; a second request while channeling must not restart the cast.
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.has(30), "tp: valid request starts the channel")
	var end0: int = int(lobby._teleports[30]["end_tick"])
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.size() == 1 and int(lobby._teleports[30]["end_tick"]) == end0,
		"tp: busy channel not restarted")
	# Cancel-on-move: any real step kills the cast, the player stays put.
	s.pos = village_pos + Vector2(10, 0)
	lobby.step_sim(t); t += 1
	_check(not lobby._teleports.has(30), "tp: moving cancels the channel")
	_check(s.pos.distance_to(g.merchants[dest_idx]) > 100.0, "tp: cancelled cast does not teleport")
	# Cancel-on-damage (no cooldown was stamped by the cancel, so restarting is allowed).
	s.pos = village_pos
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.has(30), "tp: cancelled cast may restart at once")
	s.hp -= 5
	lobby.step_sim(t); t += 1
	_check(not lobby._teleports.has(30), "tp: damage cancels the channel")
	s.hp = 100
	# Completion: stand still through the whole cast -> snap to the destination,
	# cooldown stamped, channel gone.
	var t0 := t
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t0)
	for _i in TeleportDefs.TP_CAST_TICKS + 2:
		lobby.step_sim(t); t += 1
	var want: Vector2 = g.resolve_circle(g.merchants[dest_idx], EntityDefs.radius_for(s.kind))
	_check(s.pos.distance_to(want) < 1.0, "tp: completion snaps to the destination")
	_check(not lobby._teleports.has(30), "tp: completed channel erased")
	_check(int(sp.teleport_ready_tick) == t0 + TeleportDefs.TP_CAST_TICKS + TeleportDefs.TP_COOLDOWN_TICKS,
		"tp: completion stamps the full cooldown")
	# Cooldown gate: an immediate retry is rejected; expiry re-allows exactly at
	# ready_tick (the player now stands at the mid merchant — still a waypoint).
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, t)
	_check(lobby._teleports.is_empty(), "tp: cooldown rejects an immediate retry")
	lobby.apply_teleport(30, TeleportDefs.DEST_MERCHANT, dest_idx, int(sp.teleport_ready_tick))
	_check(lobby._teleports.has(30), "tp: request at ready_tick starts a new channel")

## Shrine capture: needs SHRINE_MIN_PLAYERS of ONE faction, pays the tier award
## faction-wide exactly once, then locks out; contested stands capture nothing.
func _test_shrines() -> void:
	var lobby_script: GDScript = load("res://server/lobby.gd")
	var lobby = lobby_script.new(7, "shrines", 0, WorldGenerator.SIZE_MEDIUM, 2, 1)
	_disable_pickups(lobby)   # exact-gems assertions below
	lobby.add_member(40)
	lobby.add_member(41)
	lobby.add_member(42)
	lobby.spawn_player(40, 0, 1)
	lobby.spawn_player(41, 0, 1)
	lobby.spawn_player(42, 0, 2)
	lobby.active.clear()
	_check(lobby._shrines.size() > 0, "shrines: medium map hosts at least one shrine")
	if lobby._shrines.is_empty():
		return
	var shrine: Dictionary = lobby._shrines[0]
	var award: int = UpgradeDefs.GEM_AWARD_SHRINE_BY_TIER[int(shrine["tier"])]
	_check(award > 0, "shrines: tier >= 1 shrines pay a non-zero award")
	var a: EntityState = lobby._states[lobby._players[40].entity_id]
	var b: EntityState = lobby._states[lobby._players[41].entity_id]
	var c: EntityState = lobby._states[lobby._players[42].entity_id]
	# Raid-dummy hp: the shrine island's monsters WILL contest the channel (that
	# is the intended activity; damage does not cancel it — death would).
	a.hp = 60000
	b.hp = 60000
	c.hp = 60000
	var pos: Vector2 = shrine["pos"]
	var t := 0
	# Solo: below SHRINE_MIN_PLAYERS, progress never accrues.
	a.pos = pos
	for _i in 700:
		lobby.step_sim(t); t += 1
	_check(int(lobby._players[40].gems) == 0, "shrines: a lone player captures nothing")
	# Contested: one player of each faction is not a capturing group.
	c.pos = pos
	for _i in 100:
		lobby.step_sim(t); t += 1
	_check(int(lobby._players[40].gems) == 0 and int(lobby._players[42].gems) == 0,
		"shrines: a contested stand captures nothing")
	# Two same-faction players: full channel pays the whole faction, once.
	c.pos = pos + Vector2(5000, 0)
	b.pos = pos
	for _i in UpgradeDefs.SHRINE_CHANNEL_TICKS + 2:
		lobby.step_sim(t); t += 1
	_check(int(lobby._players[40].gems) == award and int(lobby._players[41].gems) == award,
		"shrines: full channel pays the capturing faction")
	_check(int(lobby._players[42].gems) == 0, "shrines: other faction not paid")
	# Lockout: standing through it pays nothing more.
	for _i in 700:
		lobby.step_sim(t); t += 1
	_check(int(lobby._players[40].gems) == award, "shrines: lockout blocks immediate recapture")
	# Expired lockout: capturable again.
	lobby._shrine_locked_until[0] = t
	for _i in UpgradeDefs.SHRINE_CHANNEL_TICKS + 2:
		lobby.step_sim(t); t += 1
	_check(int(lobby._players[40].gems) == 2 * award, "shrines: expired lockout allows recapture")

func _finish() -> void:
	print("boss sim test: %d checks, %d failures" % [_checks, _fails])
	print("RESULT: %s" % ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)
