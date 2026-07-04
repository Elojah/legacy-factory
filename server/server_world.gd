extends Node
## ServerWorld — the authoritative LOBBY MANAGER. It owns many Lobby worlds, ticks
## them all on the shared GameClock, and routes lobby handshake + input traffic. A
## connecting peer is NOT spawned: it sits "in the browser" until it creates/joins
## a lobby and reports ready_in_lobby. Each lobby's snapshots go only to its active
## peers. Empty lobbies are destroyed. Source of truth for every session.

var _lobbies: Dictionary = {}     # lobby_id -> Lobby
var _peer_lobby: Dictionary = {}  # peer_id -> lobby_id (absent = at the browser)
var _next_lobby_id: int = 1
var _pending_creates: Array = []  # deferred create requests (built in a normal frame)
var _seed_rng: RandomNumberGenerator

func _ready() -> void:
	# Prewarm the native RNG type in a normal frame (see the 4.7 native-.new() note);
	# this RNG only picks lobby seeds and never feeds the deterministic sim.
	_seed_rng = RandomNumberGenerator.new()
	_seed_rng.randomize()
	NetManager.peer_left.connect(_on_peer_left)
	NetManager.input_received.connect(_on_input_received)
	NetManager.lobby_list_requested.connect(_on_lobby_list_requested)
	NetManager.lobby_create_requested.connect(_on_lobby_create_requested)
	NetManager.lobby_join_requested.connect(_on_lobby_join_requested)
	NetManager.lobby_ready.connect(_on_lobby_ready)
	NetManager.lobby_leave_requested.connect(_on_lobby_leave_requested)
	NetManager.diplomacy_action_requested.connect(_on_diplomacy_action)
	NetManager.shop_purchase_requested.connect(_on_shop_purchase)
	NetManager.teleport_requested.connect(_on_teleport_request)
	print("[ServerWorld] lobby manager ready")

func _physics_process(_delta: float) -> void:
	# 1) Build any deferred lobbies (normal frame — keeps RNG/geometry off RPC frames).
	_drain_pending_creates()
	# 2) Tick every lobby on the shared global tick.
	for lid in _lobbies:
		_lobbies[lid].step_sim(GameClock.current_tick)
	# 3) Advance the clock ONCE globally, then broadcast each lobby to its peers.
	GameClock.server_advance()
	if GameClock.current_tick % NetConfig.SNAPSHOT_EVERY_TICKS == 0:
		for lid in _lobbies:
			var lob: Lobby = _lobbies[lid]
			var peers := lob.active_peers()
			if not peers.is_empty():
				NetManager.send_snapshot_to(peers, lob.make_snapshot_bytes(GameClock.current_tick))

# --- lobby lifecycle ---------------------------------------------------------
func _on_lobby_list_requested(peer_id: int) -> void:
	var list: Array = []
	for lid in _lobbies:
		list.append(_lobbies[lid].info())
	NetManager.send_lobby_list(peer_id, list)

func _on_lobby_create_requested(peer_id: int, size: int, factions: int, lobby_name: String) -> void:
	if _peer_lobby.has(peer_id):
		NetManager.send_join_rejected(peer_id, NetManager.REJECT_ALREADY_IN_LOBBY)
		return
	var clamped := clampi(size, WorldGenerator.SIZE_SMALL, WorldGenerator.SIZE_LARGE)
	var fclamped := clampi(factions, FactionDefs.MIN_LOBBY_FACTIONS, FactionDefs.MAX_LOBBY_FACTIONS)
	var clean := _sanitize_name(lobby_name)
	# Defer construction (geometry build) to the next _physics_process.
	_pending_creates.append({"peer": peer_id, "size": clamped, "factions": fclamped, "name": clean})

func _drain_pending_creates() -> void:
	if _pending_creates.is_empty():
		return
	var pending := _pending_creates
	_pending_creates = []
	for req in pending:
		var peer_id: int = req["peer"]
		# The peer may have disconnected or joined elsewhere while we waited.
		if _peer_lobby.has(peer_id) or not _is_connected(peer_id):
			continue
		var lid := _next_lobby_id
		_next_lobby_id += 1
		var seed := _seed_rng.randi()
		var lob := Lobby.new(lid, req["name"], peer_id, req["size"], req["factions"], seed)
		_lobbies[lid] = lob
		lob.add_member(peer_id)
		_peer_lobby[peer_id] = lid
		NetManager.send_join_accepted(peer_id, lid, seed, lob.size, lob.faction_count)
		print("[ServerWorld] lobby %d created by peer %d (seed=%d size=%d factions=%d)" % [lid, peer_id, seed, lob.size, lob.faction_count])

func _on_lobby_join_requested(peer_id: int, lobby_id: int) -> void:
	if _peer_lobby.has(peer_id):
		NetManager.send_join_rejected(peer_id, NetManager.REJECT_ALREADY_IN_LOBBY)
		return
	if not _lobbies.has(lobby_id):
		NetManager.send_join_rejected(peer_id, NetManager.REJECT_NOT_FOUND)
		return
	var lob: Lobby = _lobbies[lobby_id]
	if not lob.has_room():
		NetManager.send_join_rejected(peer_id, NetManager.REJECT_FULL)
		return
	# The lobby already exists (geometry built), so adding a member is safe here.
	lob.add_member(peer_id)
	_peer_lobby[peer_id] = lobby_id
	NetManager.send_join_accepted(peer_id, lobby_id, lob.seed, lob.size, lob.faction_count)
	print("[ServerWorld] peer %d joined lobby %d" % [peer_id, lobby_id])

func _on_lobby_ready(peer_id: int, appearance: int, faction: int) -> void:
	if not _peer_lobby.has(peer_id):
		return
	var lob: Lobby = _lobbies[_peer_lobby[peer_id]]
	if lob.active.has(peer_id):
		return  # already spawned (duplicate ready)
	# Validate/clamp before trusting (mirrors Lobby.push_input's input clamping).
	var clean := Appearance.sanitize(appearance)
	var f := lob.assign_faction(faction)
	var eid := lob.spawn_player(peer_id, clean, f)
	NetManager.assign_local(peer_id, eid)  # reliable: tell the client its entity
	# Dev/test hook (--grant-gems): seed spawns so the merchant loop is
	# instantly testable. Operator-controlled — server authority intact.
	lob.grant_gems(peer_id, Bootstrap.grant_gems)
	# Late-joiner pickup sync: taken orbs/caches are server-only state, so a
	# fresh peer must be told which markers to hide.
	lob.send_pickup_state(peer_id)
	print("[ServerWorld] peer %d ready in lobby %d -> entity %d (appearance=%d faction=%d)" % [peer_id, lob.id, eid, clean, f])

func _on_diplomacy_action(peer_id: int, target_faction: int, action: int) -> void:
	if _peer_lobby.has(peer_id):
		_lobbies[_peer_lobby[peer_id]].apply_diplomacy(peer_id, target_faction, action, GameClock.current_tick)

func _on_shop_purchase(peer_id: int, item_id: int) -> void:
	if _peer_lobby.has(peer_id):
		_lobbies[_peer_lobby[peer_id]].apply_purchase(peer_id, item_id)

func _on_teleport_request(peer_id: int, dest_kind: int, dest_index: int) -> void:
	if _peer_lobby.has(peer_id):
		_lobbies[_peer_lobby[peer_id]].apply_teleport(peer_id, dest_kind, dest_index, GameClock.current_tick)

func _on_lobby_leave_requested(peer_id: int) -> void:
	_leave_lobby(peer_id)

func _on_peer_left(peer_id: int) -> void:
	_leave_lobby(peer_id)
	print("[ServerWorld] peer %d disconnected" % peer_id)

func _on_input_received(peer_id: int, cmds: Array) -> void:
	if _peer_lobby.has(peer_id):
		_lobbies[_peer_lobby[peer_id]].push_input(peer_id, cmds)

# --- helpers -----------------------------------------------------------------
func _leave_lobby(peer_id: int) -> void:
	if not _peer_lobby.has(peer_id):
		return
	var lid: int = _peer_lobby[peer_id]
	_peer_lobby.erase(peer_id)
	if not _lobbies.has(lid):
		return
	var lob: Lobby = _lobbies[lid]
	lob.remove_peer(peer_id)
	if lob.is_empty():
		_lobbies.erase(lid)
		print("[ServerWorld] lobby %d destroyed (empty)" % lid)

func _is_connected(peer_id: int) -> bool:
	return peer_id in multiplayer.get_peers()

func _sanitize_name(raw: String) -> String:
	var s := raw.strip_edges()
	if s.is_empty():
		s = "Lobby"
	return s.substr(0, 24)
