extends Node
## NetManager — the single networking surface. ALL @rpc endpoints live here so
## they share one NodePath (/root/NetManager) on every peer; the active world
## (server or client) talks to the network only through these signals/methods.
## This is why server_root and client_root can have different node trees.

signal server_started
signal client_connected
signal client_connection_failed
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal input_received(peer_id: int, cmds: Array)
signal snapshot_received(snapshot: Snapshot)
signal despawn_received(entity_id: int)
signal local_player_assigned(entity_id: int)

# Lobby handshake (all reliable). Client->server requests and server->client
# responses are surfaced as signals so the manager / UI stay off the NodePath.
signal lobby_list_requested(peer_id: int)
signal lobby_create_requested(peer_id: int, size: int, factions: int, lobby_name: String)
signal lobby_join_requested(peer_id: int, lobby_id: int)
signal lobby_ready(peer_id: int, appearance: int, faction: int)
signal lobby_leave_requested(peer_id: int)
signal lobby_list_received(list: Array)
signal lobby_join_accepted_sig(lobby_id: int, seed: int, size: int, factions: int)
signal lobby_join_rejected_sig(reason: int)

# Faction diplomacy (reliable). The relation table itself rides the snapshot
# header; the event RPC exists for UI (toasts/pending proposals) and carries the
# post-mutation table + tick for a latest-wins merge on the client.
signal diplomacy_action_requested(peer_id: int, target_faction: int, action: int)
signal diplomacy_event_received(a_faction: int, b_faction: int, event_kind: int, relations: int, server_tick: int)

# Gem economy (reliable, per-peer). Purchases are validated by the Lobby (never
# trust the client); the gems_event is the ONLY carrier of the gem balance — the
# bought upgrades themselves ride EntityState.upgrades in snapshots.
signal shop_purchase_requested(peer_id: int, item_id: int)
signal gems_event_received(balance: int, delta: int, reason: int, item_id: int)

# World pickups & shrine captures (reliable, to a lobby's active peers). These
# only sync marker state / fire toasts — the gem award itself always rides the
# per-peer gems_event above, so balances can never drift.
signal orb_event_received(kind: int, index: int, taken: bool)
signal shrine_event_received(faction: int, island: int)

# Waypoint teleport (reliable request/response, validated by the Lobby — see
# Lobby.apply_teleport). `data` carries the remaining cooldown ticks in every
# reply so the client's readout is always authoritative.
signal teleport_requested(peer_id: int, dest_kind: int, dest_index: int)
signal teleport_event_received(event: int, data: int)

# Join-rejection reasons.
const REJECT_NOT_FOUND := 0
const REJECT_FULL := 1
const REJECT_ALREADY_IN_LOBBY := 2

var is_server: bool = false
# Server address the menu/browser connect to (set by Bootstrap from CLI / defaults).
var connect_ip: String = NetConfig.DEFAULT_CONNECT_IP
var connect_port: int = NetConfig.DEFAULT_PORT
var _sim := LatencySim.new()  # active on clients only (see configure_latency)

func is_connected_to_server() -> bool:
	# The default peer is an OfflineMultiplayerPeer that reports CONNECTED, so check
	# specifically for a live ENet client connection.
	var p := multiplayer.multiplayer_peer
	return p is ENetMultiplayerPeer and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _process(_dt: float) -> void:
	_sim.drain(float(Time.get_ticks_msec()))

func configure_latency(lag_ms: float, jitter_ms: float, loss: float) -> void:
	_sim.lag_ms = lag_ms
	_sim.jitter_ms = jitter_ms
	_sim.loss = loss

# --- connection lifecycle ----------------------------------------------------
func host_server(port: int) -> bool:
	is_server = true
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, NetConfig.MAX_PEERS)
	if err != OK:
		push_error("NetManager: create_server failed (%d)" % err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(func(id: int): peer_joined.emit(id))
	multiplayer.peer_disconnected.connect(func(id: int): peer_left.emit(id))
	server_started.emit()
	print("[NetManager] server listening on %d" % port)
	return true

func connect_to_server(ip: String, port: int) -> bool:
	is_server = false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		push_error("NetManager: create_client failed (%d)" % err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func(): client_connected.emit())
	multiplayer.connection_failed.connect(func(): client_connection_failed.emit())
	print("[NetManager] connecting to %s:%d" % [ip, port])
	return true

# --- outbound (latency-simulated on clients) ---------------------------------
func send_input(cmds: Array) -> void:
	var data := InputCommand.pack_batch(cmds)
	_dispatch(func(): receive_input.rpc_id(NetConfig.SERVER_PEER_ID, data))

func send_ping() -> void:
	var t := float(Time.get_ticks_msec())
	_dispatch(func(): ping.rpc_id(NetConfig.SERVER_PEER_ID, t))

func broadcast_snapshot(snapshot: Snapshot) -> void:
	receive_snapshot.rpc(snapshot.to_bytes())

func send_despawn(entity_id: int) -> void:
	despawn_entity.rpc(entity_id)

func assign_local(peer_id: int, entity_id: int) -> void:
	assign_local_player.rpc_id(peer_id, entity_id)

# --- lobby send-helpers ------------------------------------------------------
# Server->client: targeted, direct (the latency sim is client-side only; the
# server never configures it). Snapshots are pre-serialized once by the caller.
func send_snapshot_to(peers: Array, data: PackedByteArray) -> void:
	for pid in peers:
		receive_snapshot.rpc_id(pid, data)

func send_despawn_to(peers: Array, entity_id: int) -> void:
	for pid in peers:
		despawn_entity.rpc_id(pid, entity_id)

func send_lobby_list(peer_id: int, list: Array) -> void:
	receive_lobby_list.rpc_id(peer_id, list)

func send_join_accepted(peer_id: int, lobby_id: int, p_seed: int, size: int, factions: int) -> void:
	lobby_join_accepted.rpc_id(peer_id, lobby_id, p_seed, size, factions)

func send_join_rejected(peer_id: int, reason: int) -> void:
	lobby_join_rejected.rpc_id(peer_id, reason)

func send_diplomacy_event(peers: Array, a_faction: int, b_faction: int, event_kind: int, relations: int, server_tick: int) -> void:
	for pid in peers:
		diplomacy_event.rpc_id(pid, a_faction, b_faction, event_kind, relations, server_tick)

func send_gems_event(peer_id: int, balance: int, delta: int, reason: int, item_id: int) -> void:
	gems_event.rpc_id(peer_id, balance, delta, reason, item_id)

func send_orb_event(peers: Array, kind: int, index: int, taken: bool) -> void:
	for pid in peers:
		orb_event.rpc_id(pid, kind, index, taken)

func send_shrine_event(peers: Array, faction: int, island: int) -> void:
	for pid in peers:
		shrine_event.rpc_id(pid, faction, island)

func send_teleport_event(peer_id: int, event: int, data: int) -> void:
	teleport_event.rpc_id(peer_id, event, data)

# Client->server: reliable handshake, sent directly (not through the latency sim,
# which only delays unreliable gameplay traffic).
func client_request_lobby_list() -> void:
	request_lobby_list.rpc_id(NetConfig.SERVER_PEER_ID)

func client_create_lobby(size: int, factions: int, lobby_name: String) -> void:
	create_lobby.rpc_id(NetConfig.SERVER_PEER_ID, size, factions, lobby_name)

func client_join_lobby(lobby_id: int) -> void:
	join_lobby.rpc_id(NetConfig.SERVER_PEER_ID, lobby_id)

func client_ready_in_lobby(appearance: int, faction: int) -> void:
	ready_in_lobby.rpc_id(NetConfig.SERVER_PEER_ID, appearance, faction)

func client_diplomacy_action(target_faction: int, action: int) -> void:
	diplomacy_action.rpc_id(NetConfig.SERVER_PEER_ID, target_faction, action)

func client_shop_purchase(item_id: int) -> void:
	shop_purchase.rpc_id(NetConfig.SERVER_PEER_ID, item_id)

func client_request_teleport(dest_kind: int, dest_index: int) -> void:
	request_teleport.rpc_id(NetConfig.SERVER_PEER_ID, dest_kind, dest_index)

func client_leave_lobby() -> void:
	leave_lobby.rpc_id(NetConfig.SERVER_PEER_ID)

func _dispatch(cb: Callable) -> void:
	_sim.submit(float(Time.get_ticks_msec()), cb)

# --- @rpc endpoints (defined on every peer; same path everywhere) ------------
# What matters for netcode correctness is the TRANSFER MODE (reliable vs
# unreliable_ordered), so that is set explicitly. All traffic shares the default
# transfer channel (0) — splitting onto separate ENet channels is a future
# refinement (see NetConfig.CH_*), kept off here to avoid channel-count pitfalls.
#
# Client -> server: input commands. Latest supersedes older; loss is tolerable.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func receive_input(data: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	input_received.emit(sender, InputCommand.unpack_batch(data))

# Server -> clients: world snapshots. Latest supersedes older; loss is tolerable.
# Decode on receipt (NOT inside the latency lambda — a static factory call there
# trips a GDScript resolution bug), then delay only the delivery of the object.
@rpc("authority", "call_remote", "unreliable_ordered")
func receive_snapshot(data: PackedByteArray) -> void:
	var snap = Snapshot.from_bytes(data)
	_sim.submit(float(Time.get_ticks_msec()), func(): snapshot_received.emit(snap))

# Clock sync. Unreliable so RTT isn't inflated by reliable retransmit queueing.
@rpc("any_peer", "call_remote", "unreliable")
func ping(client_ms: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	pong.rpc_id(sender, client_ms, GameClock.current_tick)

@rpc("authority", "call_remote", "unreliable")
func pong(client_ms: float, server_tick: int) -> void:
	_sim.submit(float(Time.get_ticks_msec()), func(): GameClock.note_pong(client_ms, server_tick))

# Reliable lifecycle. Existence is otherwise inferred lazily from snapshots.
@rpc("authority", "call_remote", "reliable")
func despawn_entity(entity_id: int) -> void:
	despawn_received.emit(entity_id)

@rpc("authority", "call_remote", "reliable")
func assign_local_player(entity_id: int) -> void:
	local_player_assigned.emit(entity_id)

# --- lobby handshake @rpc (all reliable lifecycle) ---------------------------
# Client -> server requests.
@rpc("any_peer", "call_remote", "reliable")
func request_lobby_list() -> void:
	lobby_list_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable")
func create_lobby(size: int, factions: int, lobby_name: String) -> void:
	lobby_create_requested.emit(multiplayer.get_remote_sender_id(), size, factions, lobby_name)

@rpc("any_peer", "call_remote", "reliable")
func join_lobby(lobby_id: int) -> void:
	lobby_join_requested.emit(multiplayer.get_remote_sender_id(), lobby_id)

# Carries the player's Appearance code + faction pick so the spawn can stamp
# them onto the entity; the server sanitizes both (never trust the client).
@rpc("any_peer", "call_remote", "reliable")
func ready_in_lobby(appearance: int, faction: int) -> void:
	lobby_ready.emit(multiplayer.get_remote_sender_id(), appearance, faction)

# Faction diplomacy: client asks, the lobby validates and applies (see
# Lobby.apply_diplomacy); accepted changes come back via diplomacy_event and
# the next snapshot's relations header.
@rpc("any_peer", "call_remote", "reliable")
func diplomacy_action(target_faction: int, action: int) -> void:
	diplomacy_action_requested.emit(multiplayer.get_remote_sender_id(), target_faction, action)

# Gem shop: client asks, the lobby validates and applies (see Lobby.apply_purchase);
# the outcome (new balance + reason code) comes back via gems_event.
@rpc("any_peer", "call_remote", "reliable")
func shop_purchase(item_id: int) -> void:
	shop_purchase_requested.emit(multiplayer.get_remote_sender_id(), item_id)

# Waypoint travel: client asks, the lobby validates (near a waypoint, allowed
# destination, cooldown ready) and runs the cast server-side; every outcome
# comes back via teleport_event.
@rpc("any_peer", "call_remote", "reliable")
func request_teleport(dest_kind: int, dest_index: int) -> void:
	teleport_requested.emit(multiplayer.get_remote_sender_id(), dest_kind, dest_index)

@rpc("any_peer", "call_remote", "reliable")
func leave_lobby() -> void:
	lobby_leave_requested.emit(multiplayer.get_remote_sender_id())

# Server -> client responses.
@rpc("authority", "call_remote", "reliable")
func receive_lobby_list(list: Array) -> void:
	lobby_list_received.emit(list)

@rpc("authority", "call_remote", "reliable")
func lobby_join_accepted(lobby_id: int, p_seed: int, size: int, factions: int) -> void:
	lobby_join_accepted_sig.emit(lobby_id, p_seed, size, factions)

@rpc("authority", "call_remote", "reliable")
func lobby_join_rejected(reason: int) -> void:
	lobby_join_rejected_sig.emit(reason)

@rpc("authority", "call_remote", "reliable")
func diplomacy_event(a_faction: int, b_faction: int, event_kind: int, relations: int, server_tick: int) -> void:
	diplomacy_event_received.emit(a_faction, b_faction, event_kind, relations, server_tick)

@rpc("authority", "call_remote", "reliable")
func gems_event(balance: int, delta: int, reason: int, item_id: int) -> void:
	gems_event_received.emit(balance, delta, reason, item_id)

@rpc("authority", "call_remote", "reliable")
func orb_event(kind: int, index: int, taken: bool) -> void:
	orb_event_received.emit(kind, index, taken)

@rpc("authority", "call_remote", "reliable")
func shrine_event(faction: int, island: int) -> void:
	shrine_event_received.emit(faction, island)

@rpc("authority", "call_remote", "reliable")
func teleport_event(event: int, data: int) -> void:
	teleport_event_received.emit(event, data)
