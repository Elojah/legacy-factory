class_name Lobby extends RefCounted
## One authoritative game session on the server: its own procedural world, entity
## states, input queues, AI and players. The ServerWorld manager owns many of these
## and ticks them all on the shared GameClock. Snapshots for a lobby go only to its
## `active` peers (those that finished loading and sent ready_in_lobby).
##
## Two peer sets: `members` = joined (may still be loading the game scene);
## `active` = spawned and receiving snapshots. A peer is a member from join/create
## and becomes active on ready_in_lobby.

const RESPAWN_TICKS: int = 90  # 3 s at 30 Hz

var id: int
var lobby_name: String
var owner_peer: int
var size: int
var max_players: int
var seed: int
var geometry: WorldGeometry
var faction_count: int
# Faction diplomacy state. `relations` is the FactionDefs 2-bit pair table —
# threaded into the sim step and broadcast in every snapshot header.
var relations: int = FactionDefs.RELATIONS_ALL_NEUTRAL
var _alliance_proposals: Dictionary = {}  # pair_index -> proposing faction

var members: Dictionary = {}          # peer_id -> true (joined)
var active: Dictionary = {}           # peer_id -> true (spawned, gets snapshots)

var _states: Dictionary = {}          # entity_id -> EntityState (authoritative)
var _input_queues: Dictionary = {}    # peer_id -> InputQueue
var _players: Dictionary = {}         # peer_id -> ServerPlayer
var _respawn_timers: Dictionary = {}  # entity_id -> ticks remaining
var _ai := AIController.new()
var _boss_ai := BossAI.new()
var _boss_home: Dictionary = {}       # boss entity_id -> home position
var _monster_home: Dictionary = {}    # monster entity_id -> home (spawn/summon point)
var _next_entity_id: int = 1
var _spawn_cursors: Dictionary = {}          # faction -> round-robin cursor
var _village_idx_by_faction: Dictionary = {} # faction -> Array of village indices
# World pickups: taken orb/cache index -> the server tick it respawns at.
# SERVER-ONLY (like gems); clients mirror it via the reliable orb_event.
var _orbs_taken: Dictionary = {}
var _caches_taken: Dictionary = {}
# Waypoint teleports: peer_id -> {end_tick, dest, anchor, hp_last}. Long timers
# never fit the u8 ability fields, so the whole cast is server-side policy.
var _teleports: Dictionary = {}
# Shrine captures: list of {pos, island, tier} (derived from geometry in _init),
# progress per shrine index, and lockout expiry ticks.
var _shrines: Array = []
var _shrine_progress: Dictionary = {}        # shrine idx -> {faction, ticks}
var _shrine_locked_until: Dictionary = {}    # shrine idx -> unlock tick

func _init(p_id: int, p_name: String, p_owner: int, p_size: int, p_factions: int, p_seed: int) -> void:
	id = p_id
	lobby_name = p_name
	owner_peer = p_owner
	size = p_size
	# Re-clamped here (defense in depth — the manager clamps too).
	faction_count = clampi(p_factions, FactionDefs.MIN_LOBBY_FACTIONS, FactionDefs.MAX_LOBBY_FACTIONS)
	seed = p_seed
	# Built in a normal frame by the manager (RNG prewarmed) — safe vs the 4.7 bug.
	geometry = WorldGenerator.generate(seed, size)
	var cfg: Dictionary = WorldGenerator.PRESETS.get(size, WorldGenerator.PRESETS[WorldGenerator.SIZE_MEDIUM])
	max_players = int(cfg["players"])
	# Faction spawn book: village indices per owning faction (geometry array
	# order), consumed round-robin per faction by _next_player_spawn.
	for i in geometry.village_factions.size():
		var f: int = geometry.village_factions[i]
		if not _village_idx_by_faction.has(f):
			_village_idx_by_faction[f] = []
		_village_idx_by_faction[f].append(i)
	# Shrine points: every field island (index >= 5, non-boss) of tier >= 1 hosts
	# one at its rect center — a pure function of the geometry, so the client
	# derives the identical set for its markers (map_markers.gd).
	for i in range(5, geometry.islands.size()):
		if i in geometry.boss_islands or geometry.island_tiers[i] < 1:
			continue
		_shrines.append({"pos": geometry.islands[i].get_center(), "island": i,
			"tier": geometry.island_tiers[i]})
	_spawn_monsters()
	_spawn_bosses()

# --- membership --------------------------------------------------------------
func add_member(peer_id: int) -> void:
	members[peer_id] = true

func has_room() -> bool:
	return members.size() < max_players

func is_empty() -> bool:
	return members.is_empty()

func active_peers() -> Array:
	return active.keys()

func info() -> Dictionary:
	return {"id": id, "name": lobby_name, "players": members.size(), "max": max_players, "size": size, "factions": faction_count}

## Validate a requested faction against this lobby's count; an invalid pick
## (e.g. faction 4 in a 2-faction lobby) is auto-assigned to the least-populated
## faction, lowest id winning ties — deterministic, never Dictionary order.
func assign_faction(requested: int) -> int:
	var f := FactionDefs.sanitize_faction(requested, faction_count)
	if f != FactionDefs.FACTION_NONE:
		return f
	var counts: Dictionary = {}
	for i in range(FactionDefs.FACTION_FIRST, faction_count + 1):
		counts[i] = 0
	for pid in _players:
		var pf: int = _players[pid].faction
		if counts.has(pf):
			counts[pf] += 1
	var best: int = FactionDefs.FACTION_FIRST
	for i in range(FactionDefs.FACTION_FIRST + 1, faction_count + 1):
		if counts[i] < counts[best]:
			best = i
	return best

## Spawn the peer's player entity and mark them active (snapshot recipient).
## `appearance` and `faction` are already sanitized/validated by the manager
## (never trust the client).
func spawn_player(peer_id: int, appearance: int, faction: int) -> int:
	var st := EntityState.new()
	st.id = _alloc_id()
	st.kind = NetConfig.KIND_PLAYER
	st.hp = NetConfig.PLAYER_MAX_HP
	st.pos = _next_player_spawn(faction)
	st.facing = Vector2.DOWN
	st.appearance = appearance
	st.faction = faction
	_states[st.id] = st
	_input_queues[peer_id] = InputQueue.new()
	_players[peer_id] = ServerPlayer.new(peer_id, st.id, appearance, faction)
	active[peer_id] = true
	return st.id

func remove_peer(peer_id: int) -> void:
	members.erase(peer_id)
	active.erase(peer_id)
	_input_queues.erase(peer_id)
	_teleports.erase(peer_id)
	if _players.has(peer_id):
		var eid: int = _players[peer_id].entity_id
		_states.erase(eid)
		_respawn_timers.erase(eid)
		_players.erase(peer_id)
		# Tell the remaining active peers (the leaver is already out of `active`).
		NetManager.send_despawn_to(active.keys(), eid)

# --- per-tick ----------------------------------------------------------------
func push_input(peer_id: int, cmds: Array) -> void:
	if not _input_queues.has(peer_id):
		return
	# Validate/clamp before trusting: cap move length and mask unknown button bits.
	# (NOVA/VOLLEY pass the mask; the sim ladder still requires their unlock bit.)
	for c in cmds:
		c.move = c.move.limit_length(1.0)
		c.buttons &= (NetConfig.BTN_ATTACK | NetConfig.BTN_INTERACT
			| NetConfig.BTN_BOLT | NetConfig.BTN_DASH | NetConfig.BTN_HEAL | NetConfig.BTN_SLAM
			| NetConfig.BTN_NOVA | NetConfig.BTN_VOLLEY)
	_input_queues[peer_id].push(cmds)

func step_sim(server_tick: int) -> void:
	# 1) One input per player for this tick.
	var inputs: Dictionary = {}
	for peer_id in _input_queues:
		var cmd: InputCommand = _input_queues[peer_id].pop_next()
		var eid: int = _players[peer_id].entity_id if _players.has(peer_id) else -1
		if eid != -1 and cmd != null:
			inputs[eid] = cmd
	# 2) AI fills inputs for monsters, then bosses (disjoint kinds).
	_ai.produce(_states, inputs, _monster_home)
	_boss_ai.produce(_states, inputs)
	# 3) Authoritative step against this lobby's geometry + faction relations.
	WorldSim.step(_states, inputs, geometry, server_tick, relations)
	# 4) Server-only entity lifecycle: bolts/barrages, boss summons and hazard
	#    zones spawn here, never inside the shared step (ids are
	#    server-allocated; clients never spawn entities).
	_spawn_bolts()
	_spawn_summons()
	_spawn_hazards()
	_reap_transients()
	# 4b) Server-only world interactions, after the step so damage dealt THIS
	#     tick cancels a teleport channel, and before respawns move the dead.
	_tick_teleports(server_tick)
	_tick_pickups(server_tick)
	_tick_shrines(server_tick)
	# 5) Server-only respawn policy (after reaping so transients never respawn),
	#    then the raid reset (boss back at home + out of combat -> full heal).
	_handle_respawns()
	_handle_boss_reset()

func make_snapshot_bytes(server_tick: int) -> PackedByteArray:
	return Snapshot.from_states(server_tick, _states, relations).to_bytes()

## Apply one diplomacy request from a peer. Validates EVERYTHING (never trust
## the client): membership, sender faction, target range. Escalation (rivalry,
## breaking an alliance) is unilateral; alliances need MUTUAL proposals — the
## UI's "Accept" simply proposes back, which is race-free (two simultaneous
## proposals just form the alliance). Relation changes ride the next snapshot's
## header; the reliable event below is UI-only (toasts + pending proposals).
func apply_diplomacy(peer_id: int, target_faction: int, action: int, server_tick: int) -> void:
	# _players membership implies active (spawn_player sets both, remove_peer
	# erases both) — one check covers "spawned in this lobby".
	if not _players.has(peer_id):
		return
	var sender: int = _players[peer_id].faction
	var target := FactionDefs.sanitize_faction(target_faction, faction_count)
	if sender == FactionDefs.FACTION_NONE or target == FactionDefs.FACTION_NONE or target == sender:
		return
	var pi := FactionDefs.pair_index(sender, target)
	var rel := FactionDefs.relation_of(sender, target, relations)
	match action:
		FactionDefs.DIPLO_DECLARE_RIVALRY:
			if rel == FactionDefs.REL_RIVAL:
				return
			relations = FactionDefs.set_relation(relations, sender, target, FactionDefs.REL_RIVAL)
			_alliance_proposals.erase(pi)
			NetManager.send_diplomacy_event(active.keys(), sender, target,
				FactionDefs.EVENT_RIVALRY_DECLARED, relations, server_tick)
		FactionDefs.DIPLO_PROPOSE_ALLIANCE:
			if rel == FactionDefs.REL_ALLIED:
				return
			if _alliance_proposals.get(pi, FactionDefs.FACTION_NONE) == target:
				# They asked first — this proposal accepts (works from RIVAL too:
				# mutual proposals are the peace path).
				relations = FactionDefs.set_relation(relations, sender, target, FactionDefs.REL_ALLIED)
				_alliance_proposals.erase(pi)
				NetManager.send_diplomacy_event(active.keys(), sender, target,
					FactionDefs.EVENT_ALLIANCE_FORMED, relations, server_tick)
			elif _alliance_proposals.get(pi, FactionDefs.FACTION_NONE) != sender:
				_alliance_proposals[pi] = sender
				NetManager.send_diplomacy_event(active.keys(), sender, target,
					FactionDefs.EVENT_ALLIANCE_PROPOSED, relations, server_tick)
		FactionDefs.DIPLO_BREAK_ALLIANCE:
			if rel != FactionDefs.REL_ALLIED:
				return
			relations = FactionDefs.set_relation(relations, sender, target, FactionDefs.REL_NEUTRAL)
			_alliance_proposals.erase(pi)
			NetManager.send_diplomacy_event(active.keys(), sender, target,
				FactionDefs.EVENT_ALLIANCE_BROKEN, relations, server_tick)

## Apply one merchant purchase. Validates EVERYTHING server-side (never trust
## the client): membership, item id, alive, merchant range (authoritative pos),
## availability, funds. On success the upgrade lands on the ENTITY (rides the
## next snapshot like any sim state); the gem balance travels only in the
## reliable gems_event reply — success and every rejection get one.
func apply_purchase(peer_id: int, item_id: int) -> void:
	if not _players.has(peer_id):
		return
	var sp: ServerPlayer = _players[peer_id]
	if item_id < 0 or item_id >= UpgradeDefs.ITEM_COUNT:
		_send_gems(peer_id, sp.gems, 0, UpgradeDefs.GEMS_REJECT_INVALID, item_id)
		return
	var s: EntityState = _states.get(sp.entity_id, null)
	if s == null or not s.is_alive():
		_send_gems(peer_id, sp.gems, 0, UpgradeDefs.GEMS_REJECT_DEAD, item_id)
		return
	if not _near_merchant(s.pos):
		_send_gems(peer_id, sp.gems, 0, UpgradeDefs.GEMS_REJECT_RANGE, item_id)
		return
	if not UpgradeDefs.item_available(item_id, s.upgrades):
		_send_gems(peer_id, sp.gems, 0, UpgradeDefs.GEMS_REJECT_MAXED, item_id)
		return
	var cost := UpgradeDefs.item_cost(item_id, s.upgrades)
	if sp.gems < cost:
		_send_gems(peer_id, sp.gems, 0, UpgradeDefs.GEMS_REJECT_FUNDS, item_id)
		return
	sp.gems -= cost
	s.upgrades = UpgradeDefs.apply_item(s.upgrades, item_id)
	_send_gems(peer_id, sp.gems, -cost, UpgradeDefs.GEMS_PURCHASE_OK, item_id)

## Dev/test hook: seed a spawned peer with gems (--grant-gems on the SERVER
## command line — operator-controlled, so authority is intact).
func grant_gems(peer_id: int, amount: int) -> void:
	if amount <= 0 or not _players.has(peer_id):
		return
	var sp: ServerPlayer = _players[peer_id]
	sp.gems += amount
	_send_gems(peer_id, sp.gems, amount, UpgradeDefs.GEMS_GRANT, -1)

func _near_merchant(pos: Vector2) -> bool:
	for m in geometry.merchants:
		if pos.distance_to(m) <= UpgradeDefs.MERCHANT_RANGE:
			return true
	return false

## Apply one waypoint-travel request. Validates EVERYTHING server-side (the
## apply_purchase discipline): membership, alive, not already channeling,
## cooldown ready, near a waypoint (authoritative pos), allowed destination.
## The cast then runs in _tick_teleports; success and every rejection answer
## with a teleport_event.
func apply_teleport(peer_id: int, dest_kind: int, dest_index: int, server_tick: int) -> void:
	if not _players.has(peer_id):
		return
	var sp: ServerPlayer = _players[peer_id]
	var s: EntityState = _states.get(sp.entity_id, null)
	if s == null or not s.is_alive():
		_send_teleport(peer_id, TeleportDefs.REJECT_DEAD, 0)
		return
	if _teleports.has(peer_id):
		_send_teleport(peer_id, TeleportDefs.REJECT_BUSY, 0)
		return
	if server_tick < sp.teleport_ready_tick:
		_send_teleport(peer_id, TeleportDefs.REJECT_COOLDOWN, sp.teleport_ready_tick - server_tick)
		return
	if not TeleportDefs.near_waypoint(geometry, s.pos):
		_send_teleport(peer_id, TeleportDefs.REJECT_RANGE, 0)
		return
	if not TeleportDefs.can_teleport_to(geometry, sp.faction, dest_kind, dest_index):
		_send_teleport(peer_id, TeleportDefs.REJECT_DENIED, 0)
		return
	_teleports[peer_id] = {
		"end_tick": server_tick + TeleportDefs.TP_CAST_TICKS,
		"dest": TeleportDefs.dest_pos(geometry, dest_kind, dest_index),
		"anchor": s.pos,
		"hp_last": s.hp,
	}
	_send_teleport(peer_id, TeleportDefs.EVENT_STARTED, 0)

## Advance the running teleport channels. Cancel-on-move/damage instead of
## rooting keeps the shared sim untouched: the channeling player stands still
## voluntarily, so prediction stays exact and the completion snap is absorbed
## by the client's normal hard reconcile.
func _tick_teleports(server_tick: int) -> void:
	for pid in _teleports.keys():
		var ch: Dictionary = _teleports[pid]
		var sp: ServerPlayer = _players.get(pid, null)
		var s: EntityState = _states.get(sp.entity_id, null) if sp != null else null
		if s == null or not s.is_alive():
			_teleports.erase(pid)
			_send_teleport(pid, TeleportDefs.EVENT_CANCELLED_DEAD, 0)
			continue
		if s.hp < int(ch["hp_last"]):
			_teleports.erase(pid)
			_send_teleport(pid, TeleportDefs.EVENT_CANCELLED_DAMAGED, 0)
			continue
		ch["hp_last"] = s.hp   # track heals so a LATER hit still reads as damage
		if s.pos.distance_to(ch["anchor"]) > TeleportDefs.TP_MOVE_TOLERANCE:
			_teleports.erase(pid)
			_send_teleport(pid, TeleportDefs.EVENT_CANCELLED_MOVED, 0)
			continue
		if server_tick >= int(ch["end_tick"]):
			s.pos = geometry.resolve_circle(ch["dest"], EntityDefs.radius_for(s.kind))
			s.vel = Vector2.ZERO
			sp.teleport_ready_tick = server_tick + TeleportDefs.TP_COOLDOWN_TICKS
			_teleports.erase(pid)
			_send_teleport(pid, TeleportDefs.EVENT_COMPLETED, TeleportDefs.TP_COOLDOWN_TICKS)

## Walk-over pickups: resource orbs and secret caches, detected on the server
## tick from AUTHORITATIVE positions — no input bit needed (the u8 buttons
## field is full). Taken state is server-only; clients mirror it through the
## reliable orb_event while the award itself rides the per-peer gems_event.
func _tick_pickups(server_tick: int) -> void:
	for i in _orbs_taken.keys():
		if server_tick >= int(_orbs_taken[i]):
			_orbs_taken.erase(i)
			_send_orb(0, i, false)
	for i in _caches_taken.keys():
		if server_tick >= int(_caches_taken[i]):
			_caches_taken.erase(i)
			_send_orb(1, i, false)
	var pids := _players.keys()
	pids.sort()   # fixed claim order when two players stand on one orb
	for pid in pids:
		var sp: ServerPlayer = _players[pid]
		var s: EntityState = _states.get(sp.entity_id, null)
		if s == null or not s.is_alive():
			continue
		for i in geometry.resources.size():
			if _orbs_taken.has(i):
				continue
			if s.pos.distance_to(geometry.resources[i]) <= UpgradeDefs.ORB_PICKUP_RANGE:
				_orbs_taken[i] = server_tick + UpgradeDefs.ORB_RESPAWN_TICKS
				var award: int = UpgradeDefs.GEM_AWARD_ORB_BY_TIER[geometry.resource_tiers[i]]
				sp.gems += award
				_send_gems(pid, sp.gems, award, UpgradeDefs.GEMS_AWARD_ORB, -1)
				_send_orb(0, i, true)
		for i in geometry.caches.size():
			if _caches_taken.has(i):
				continue
			if s.pos.distance_to(geometry.caches[i]) <= UpgradeDefs.ORB_PICKUP_RANGE:
				_caches_taken[i] = server_tick + UpgradeDefs.CACHE_RESPAWN_TICKS
				var award: int = UpgradeDefs.GEM_AWARD_CACHE_BY_TIER[geometry.cache_tiers[i]]
				sp.gems += award
				_send_gems(pid, sp.gems, award, UpgradeDefs.GEMS_AWARD_CACHE, -1)
				_send_orb(1, i, true)

## Shrine capture (the co-op activity): >= SHRINE_MIN_PLAYERS living players of
## ONE faction inside SHRINE_RADIUS accrue progress; a full channel pays the
## tier award to EVERY player of that faction and locks the shrine. Contested
## or vacant shrines reset. Deliberately does NOT cancel on damage — defending
## the channel against the island's monsters IS the activity.
func _tick_shrines(server_tick: int) -> void:
	for si in _shrines.size():
		if server_tick < int(_shrine_locked_until.get(si, 0)):
			continue
		var shrine: Dictionary = _shrines[si]
		var counts: Dictionary = {}
		for pid in _players:
			var s: EntityState = _states.get(_players[pid].entity_id, null)
			if s != null and s.is_alive() \
			and s.pos.distance_to(shrine["pos"]) <= UpgradeDefs.SHRINE_RADIUS:
				counts[_players[pid].faction] = counts.get(_players[pid].faction, 0) + 1
		var capturing := 0
		for f in range(FactionDefs.FACTION_FIRST, faction_count + 1):
			if counts.get(f, 0) >= UpgradeDefs.SHRINE_MIN_PLAYERS:
				capturing = f
				break   # lowest faction id wins a (rare) simultaneous stand-off
		if capturing == 0:
			_shrine_progress.erase(si)
			continue
		var prog: Dictionary = _shrine_progress.get(si, {"faction": capturing, "ticks": 0})
		if int(prog["faction"]) != capturing:
			prog = {"faction": capturing, "ticks": 0}
		prog["ticks"] = int(prog["ticks"]) + 1
		_shrine_progress[si] = prog
		if int(prog["ticks"]) < UpgradeDefs.SHRINE_CHANNEL_TICKS:
			continue
		_shrine_progress.erase(si)
		_shrine_locked_until[si] = server_tick + UpgradeDefs.SHRINE_LOCKOUT_TICKS
		var award: int = UpgradeDefs.GEM_AWARD_SHRINE_BY_TIER[int(shrine["tier"])]
		for pid in _players:
			var sp: ServerPlayer = _players[pid]
			if sp.faction == capturing:
				sp.gems += award
				_send_gems(pid, sp.gems, award, UpgradeDefs.GEMS_AWARD_SHRINE, -1)
		var peers := active.keys()
		if not peers.is_empty():
			NetManager.send_shrine_event(peers, capturing, int(shrine["island"]))

## Late-joiner sync: replay the currently-taken pickups to one fresh peer
## (bounded by the geometry's orb/cache counts — tens of sends at worst).
func send_pickup_state(peer_id: int) -> void:
	if not active.has(peer_id):
		return
	for i in _orbs_taken:
		NetManager.send_orb_event([peer_id], 0, i, true)
	for i in _caches_taken:
		NetManager.send_orb_event([peer_id], 1, i, true)

## Broadcast one pickup state flip (kind 0 = orb, 1 = cache) to this lobby's
## active peers. Empty `active` (the --script tests) never reaches NetManager.
func _send_orb(kind: int, index: int, taken: bool) -> void:
	var peers := active.keys()
	if not peers.is_empty():
		NetManager.send_orb_event(peers, kind, index, taken)

## Reliable per-peer teleport notification, `active`-gated like _send_gems so
## the --script tests can drive apply_teleport/_tick_teleports directly.
func _send_teleport(peer_id: int, event: int, data: int) -> void:
	if active.has(peer_id):
		NetManager.send_teleport_event(peer_id, event, data)

## Reliable per-peer gems notification, gated on `active`: under --script tests
## the NetManager autoload is unreachable and the test clears `active`, so the
## send is skipped while the gems/upgrades mutations stay assertable.
func _send_gems(peer_id: int, balance: int, delta: int, reason: int, item_id: int) -> void:
	if active.has(peer_id):
		NetManager.send_gems_event(peer_id, balance, delta, reason, item_id)

# --- spawning / respawning ---------------------------------------------------
## Monsters carry their island's danger tier in upgrades bits 0-1 (UpgradeDefs
## npc_tier): it scales melee damage through the shared sim and max hp through
## EntityDefs.max_hp_of. Their spawn point is their AI home (leash anchor).
func _spawn_monsters() -> void:
	for i in geometry.monster_spawns.size():
		var st := EntityState.new()
		st.id = _alloc_id()
		st.kind = NetConfig.KIND_MONSTER
		st.upgrades = UpgradeDefs.npc_tier_pack(geometry.monster_tiers[i])
		st.hp = EntityDefs.max_hp_of(st)
		st.pos = geometry.monster_spawns[i]
		st.facing = Vector2.LEFT
		_states[st.id] = st
		_monster_home[st.id] = st.pos

## One boss per geometry boss spawn; its kit rides the visual-only appearance
## field so remote clients can tint/draw it without any extra wire data, and its
## danger tier rides upgrades bits 0-1 (tiered max hp + gem award — the center
## apex is the full 45k raid boss).
func _spawn_bosses() -> void:
	for i in geometry.boss_spawns.size():
		var st := EntityState.new()
		st.id = _alloc_id()
		st.kind = NetConfig.KIND_BOSS
		st.upgrades = UpgradeDefs.npc_tier_pack(geometry.boss_tiers[i])
		st.hp = EntityDefs.max_hp_of(st)
		st.pos = geometry.boss_spawns[i]
		st.facing = Vector2.DOWN
		st.appearance = geometry.boss_kits[i]
		_states[st.id] = st
		_boss_home[st.id] = st.pos
		_boss_ai.register(st.id, st.pos, geometry.boss_kits[i])

## Spawn projectiles on the first ACTIVE tick of a cast (timer is still at full
## ACTIVE duration exactly once): one bolt along facing, or a radial ring for a
## boss barrage. Runs right after the sim step, so they ride out in this same
## tick's snapshot.
func _spawn_bolts() -> void:
	var spawned: Array = []
	for eid in _states:
		var s: EntityState = _states[eid]
		if not EntityDefs.is_actor(s.kind) or s.ability_phase != Ability.PHASE_ACTIVE:
			continue
		var dir := s.facing.normalized() if s.facing.length() > 0.001 else Vector2.DOWN
		if s.ability_id == AbilityDefs.BOLT \
		and s.ability_timer == AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOLT]:
			spawned.append(_make_projectile(s, dir, AbilityDefs.BOLT,
				AbilityDefs.BOLT_SPEED, AbilityDefs.BOLT_TTL_TICKS))
		elif s.ability_id == AbilityDefs.VOLLEY \
		and s.ability_timer == AbilityDefs.ACTIVE_TICKS[AbilityDefs.VOLLEY]:
			for k in AbilityDefs.VOLLEY_COUNT:
				var vd := dir.rotated(deg_to_rad(AbilityDefs.VOLLEY_SPREAD_DEGREES) * float(k - 1))
				spawned.append(_make_projectile(s, vd, AbilityDefs.VOLLEY,
					AbilityDefs.VOLLEY_SPEED, AbilityDefs.VOLLEY_TTL_TICKS))
		elif s.ability_id == AbilityDefs.BOSS_BARRAGE \
		and s.ability_timer == AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_BARRAGE]:
			for k in AbilityDefs.BARRAGE_COUNT:
				var d := dir.rotated(TAU * float(k) / float(AbilityDefs.BARRAGE_COUNT))
				spawned.append(_make_projectile(s, d, AbilityDefs.BOSS_BARRAGE,
					AbilityDefs.BARRAGE_SPEED, AbilityDefs.BARRAGE_TTL_TICKS))
	for b in spawned:  # insert after the scan — never mutate while iterating
		_states[b.id] = b

func _make_projectile(caster: EntityState, dir: Vector2, aid: int, speed: float, ttl: int) -> EntityState:
	var b := EntityState.new()
	b.id = _alloc_id()
	b.kind = NetConfig.KIND_PROJECTILE
	b.hp = 1
	b.owner_id = caster.id
	# Player bolts inherit the caster's faction; boss barrages inherit 0 =
	# hostile to everyone.
	b.faction = caster.faction
	b.upgrades = caster.upgrades  # so flight damage scales off the caster's levels
	b.ability_id = aid   # damage key (shared sim) + tint (client)
	b.facing = dir
	b.vel = dir * speed
	b.pos = caster.pos + dir * (EntityDefs.radius_for(caster.kind) + AbilityDefs.BOLT_RADIUS + AbilityDefs.BOLT_SPAWN_GAP)
	b.ability_timer = ttl  # TTL for projectiles
	return b

## Boss summon: on the cast's first ACTIVE tick, ring minions around the boss.
## Minions are plain KIND_MONSTER (the existing AIController drives them) tagged
## with owner_id = boss, capped per boss, and never respawn (see respawns).
func _spawn_summons() -> void:
	var spawned: Array = []
	for eid in _states:
		var s: EntityState = _states[eid]
		if s.kind != NetConfig.KIND_BOSS:
			continue
		if s.ability_id != AbilityDefs.BOSS_SUMMON or s.ability_phase != Ability.PHASE_ACTIVE:
			continue
		if s.ability_timer != AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_SUMMON]:
			continue
		var live := 0
		for mid in _states:
			var t: EntityState = _states[mid]
			if t.kind == NetConfig.KIND_MONSTER and t.owner_id == s.id and t.is_alive():
				live += 1
		for k in maxi(0, mini(AbilityDefs.SUMMON_COUNT, AbilityDefs.SUMMON_MAX_LIVE - live)):
			var off := Vector2.RIGHT.rotated(TAU * float(k) / float(AbilityDefs.SUMMON_COUNT)) \
				* (NetConfig.BOSS_RADIUS + 24.0)
			var st := EntityState.new()
			st.id = _alloc_id()
			st.kind = NetConfig.KIND_MONSTER
			st.upgrades = s.upgrades  # inherit the boss's danger tier: tougher adds at the center
			st.hp = EntityDefs.max_hp_of(st)
			st.owner_id = s.id
			st.pos = geometry.resolve_circle(s.pos + off, NetConfig.ENTITY_RADIUS)
			st.facing = s.facing
			st.appearance = s.appearance  # kit, for client tinting
			spawned.append(st)
	for st in spawned:
		_states[st.id] = st
		_monster_home[st.id] = st.pos  # leash anchor (minions never respawn)

## Boss hazard: drop damage zones under the nearest players (deterministic order:
## distance, then id). Zones are KIND_HAZARD with ability_timer as TTL; the
## shared sim ticks their damage, we reap them like projectiles.
func _spawn_hazards() -> void:
	var spawned: Array = []
	for eid in _states:
		var s: EntityState = _states[eid]
		if s.kind != NetConfig.KIND_BOSS:
			continue
		if s.ability_id != AbilityDefs.BOSS_HAZARD or s.ability_phase != Ability.PHASE_ACTIVE:
			continue
		if s.ability_timer != AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_HAZARD]:
			continue
		var players: Array = []
		for pid in _states:
			var t: EntityState = _states[pid]
			if t.kind == NetConfig.KIND_PLAYER and t.is_alive():
				players.append([s.pos.distance_squared_to(t.pos), t.id])
		players.sort()
		for k in mini(AbilityDefs.HAZARD_SPAWN_COUNT, players.size()):
			var under: EntityState = _states[players[k][1]]
			var hz := EntityState.new()
			hz.id = _alloc_id()
			hz.kind = NetConfig.KIND_HAZARD
			hz.hp = 1
			hz.owner_id = s.id
			hz.ability_id = AbilityDefs.BOSS_HAZARD
			hz.ability_timer = AbilityDefs.HAZARD_TTL_TICKS
			hz.pos = under.pos
			hz.appearance = s.appearance  # kit, for client tinting
			spawned.append(hz)
	for hz in spawned:
		_states[hz.id] = hz

## Remove dead transients — projectiles (hit / wall / TTL) and expired hazard
## zones — and tell clients reliably.
func _reap_transients() -> void:
	var dead: Array = []
	for eid in _states:
		var s: EntityState = _states[eid]
		if (s.kind == NetConfig.KIND_PROJECTILE or s.kind == NetConfig.KIND_HAZARD) and s.hp <= 0:
			dead.append(eid)
	for eid in dead:
		_states.erase(eid)
		NetManager.send_despawn_to(active.keys(), eid)

func _handle_respawns() -> void:
	var reaped: Array = []
	for eid in _states:
		var s: EntityState = _states[eid]
		if s.kind == NetConfig.KIND_PROJECTILE or s.kind == NetConfig.KIND_HAZARD:
			continue  # transients are reaped, never respawned
		if s.hp > 0:
			_respawn_timers.erase(eid)
			continue
		if not _respawn_timers.has(eid):
			if s.kind == NetConfig.KIND_BOSS:
				_respawn_timers[eid] = BossDefs.BOSS_RESPAWN_TICKS
				_on_boss_death(eid)
			elif _is_minion(s):
				_respawn_timers[eid] = BossDefs.MINION_REAP_TICKS
			else:
				_respawn_timers[eid] = RESPAWN_TICKS
				if s.kind == NetConfig.KIND_MONSTER:
					_award_monster_kill(s)  # once per death, same edge as the timer arm
			continue
		_respawn_timers[eid] -= 1
		if _respawn_timers[eid] <= 0:
			if _is_minion(s):
				reaped.append(eid)  # summons never come back: corpse despawns
				continue
			s.hp = EntityDefs.max_hp_of(s)  # per-entity: VIGOR players refill to 125
			s.pos = _respawn_pos(s)
			s.vel = Vector2.ZERO
			s.ability_id = 0
			s.ability_phase = Ability.PHASE_IDLE
			s.ability_timer = 0
			s.ability_has_hit = false
			s.last_hit_by = 0  # stale kill credit must not survive a revive
			for i in AbilityDefs.ABILITY_COUNT:
				s.ability_cds[i] = 0
			_respawn_timers.erase(eid)
			if s.kind == NetConfig.KIND_BOSS:
				_boss_ai.reset(eid)
	for eid in reaped:
		_states.erase(eid)
		_respawn_timers.erase(eid)
		_monster_home.erase(eid)
		NetManager.send_despawn_to(active.keys(), eid)

## A summoned minion: a monster owned by a boss.
func _is_minion(s: EntityState) -> bool:
	return s.kind == NetConfig.KIND_MONSTER and s.owner_id != 0

## Pay the last-hitter for a plain monster kill: (tier + 1) gems. Minions never
## reach here (the _is_minion branch above) — boss summon cycles must not be a
## gem farm. A vanished killer forfeits; only players hold factions 1..4.
func _award_monster_kill(s: EntityState) -> void:
	var killer: EntityState = _states.get(s.last_hit_by, null)
	if killer == null or killer.kind != NetConfig.KIND_PLAYER or killer.faction == FactionDefs.FACTION_NONE:
		return
	for pid in _players:
		var sp: ServerPlayer = _players[pid]
		if sp.entity_id == killer.id:
			var award := UpgradeDefs.monster_award_for(s.upgrades)
			sp.gems += award
			_send_gems(pid, sp.gems, award, UpgradeDefs.GEMS_AWARD_MONSTER, -1)
			return

## A boss kill takes its summons and zones with it (they die and get reaped /
## corpse-timered by the usual paths) and pays out gems: EVERY player in the
## last-hitter's faction earns the boss's TIERED award (boss_award_for — the
## center apex pays most). Fires exactly once per death (guarded by the
## _respawn_timers check in _handle_respawns).
func _on_boss_death(boss_id: int) -> void:
	for eid in _states:
		var s: EntityState = _states[eid]
		if s.owner_id == boss_id and (s.kind == NetConfig.KIND_MONSTER or s.kind == NetConfig.KIND_HAZARD):
			s.hp = 0
	_boss_ai.reset(boss_id)
	var boss: EntityState = _states[boss_id]
	var killer: EntityState = _states.get(boss.last_hit_by, null)
	# A vanished killer (left the lobby) forfeits the payout; only players hold
	# factions 1..4, so monster/hazard "kills" can never credit anyone.
	if killer == null or killer.kind != NetConfig.KIND_PLAYER or killer.faction == FactionDefs.FACTION_NONE:
		return
	var award := UpgradeDefs.boss_award_for(boss.upgrades)  # tiered: the apex pays most
	for pid in _players:
		var sp: ServerPlayer = _players[pid]
		if sp.faction == killer.faction:
			sp.gems += award
			_send_gems(pid, sp.gems, award, UpgradeDefs.GEMS_AWARD_BOSS, -1)

## Classic raid reset: a living boss standing at home, hurt, with no living
## player in aggro range heals to full (blocks leash-griefing it down in trips).
func _handle_boss_reset() -> void:
	for eid in _boss_home:
		var s: EntityState = _states.get(eid, null)
		if s == null or not s.is_alive() or s.hp >= EntityDefs.max_hp_of(s):
			continue
		if s.pos.distance_to(_boss_home[eid]) > 16.0:
			continue
		if _any_player_within(s.pos, BossDefs.AGGRO_RADIUS):
			continue
		s.hp = EntityDefs.max_hp_of(s)  # tiered max: outer bosses are weaker
		s.last_hit_by = 0  # a raid reset clears kill credit with the damage
		_boss_ai.reset(eid)

func _any_player_within(pos: Vector2, radius: float) -> bool:
	for eid in _states:
		var s: EntityState = _states[eid]
		if s.kind == NetConfig.KIND_PLAYER and s.is_alive() and pos.distance_to(s.pos) <= radius:
			return true
	return false

func _respawn_pos(s: EntityState) -> Vector2:
	if s.kind == NetConfig.KIND_BOSS:
		return _boss_home.get(s.id, s.pos)
	if s.kind == NetConfig.KIND_MONSTER:
		# Its OWN home point — never another island's (that would carry its
		# danger tier out of the ring the generator placed it in).
		return _monster_home.get(s.id, s.pos)
	return _next_player_spawn(s.faction)

## Round-robin over the player's faction's corner villages (spawn AND respawn).
## Unknown faction / no tagged villages falls back to all villages (defensive —
## the generator always tags all four corners).
func _next_player_spawn(faction: int) -> Vector2:
	var vs := geometry.villages
	if vs.is_empty():
		return Vector2.ZERO
	var idx: Array = _village_idx_by_faction.get(faction, [])
	if idx.is_empty():
		var c0 := int(_spawn_cursors.get(0, 0))
		_spawn_cursors[0] = c0 + 1
		return vs[c0 % vs.size()]
	var c := int(_spawn_cursors.get(faction, 0))
	_spawn_cursors[faction] = c + 1
	return vs[idx[c % idx.size()]]

func _alloc_id() -> int:
	var eid := _next_entity_id
	_next_entity_id += 1
	return eid
