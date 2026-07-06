extends Node
## ClientWorld — owns rendering and the client-side netcode:
##  * predicts the local player every physics tick and sends inputs,
##  * reconciles the local player against authoritative snapshots,
##  * interpolates remote entities a few ticks in the past.
## Entity existence is inferred lazily from snapshots; only the local-player
## assignment and despawns travel reliably.

const PLAYER_SCENE := preload("res://entities/player.tscn")
const MONSTER_SCENE := preload("res://entities/monster.tscn")
const PROJECTILE_SCENE := preload("res://entities/projectile.tscn")
const HAZARD_SCENE := preload("res://entities/hazard.tscn")
const TEST_MAP := preload("res://world/test_map.tscn")

const BOSS_BAR_RANGE := 800.0   # show the raid frame when a boss is this close

var _entities: Dictionary = {}   # entity_id -> GameEntity node
var _interp: Dictionary = {}     # entity_id -> InterpolationBuffer
var _geometry: WorldGeometry  # lobby world (built in _ready, before any prediction)
var _map: TestMap             # visual map (floor/water/markers/foliage); fed synced phases

var local_entity_id: int = -1
var predicted_state: EntityState = null
var _prediction := PredictionBuffer.new()
var _next_seq: int = 0

var reconcile_error_px: float = 0.0
var _last_snap_tick: int = 0
var _ping_accum: float = 0.0

# Latest known faction relations table (snapshot header, latest-wins vs the
# reliable diplomacy_event). All-neutral before the first snapshot = no PvP.
var _relations: int = FactionDefs.RELATIONS_ALL_NEUTRAL
var _relations_tick: int = -1
# Pending alliance proposals (pair_index -> proposing faction). UI only — the
# server owns the real bookkeeping. Known v1 gap: a late joiner doesn't see
# proposals made before they joined; proposing on such a pair just forms the
# alliance server-side.
var _pending_proposals: Dictionary = {}

# Gem balance, fed exclusively by the reliable gems_event RPC (never snapshots).
var _gems: int = 0
# Last upgrades bitfield pushed to the shop panel — refreshes it when a bought
# upgrade lands via snapshot (reliable vs unreliable ordering is undefined).
var _last_upgrades: int = -1

# Waypoint teleport UI state, fed by the reliable teleport_event RPC. The cast
# bar is driven off the synced clock from the STARTED event; the ready tick is
# an estimate for the panel readout only — the server enforces the real one.
var _tp_cast_start_tick: float = -1.0   # est server tick the channel started; -1 = idle
var _tp_ready_tick: float = 0.0         # est server tick travel is ready again
var _auto_tp_accum: float = 0.0         # --auto-tp bot retry timer

# Cosmetic scroll/flow rates per synced tick. Kept here (client-side, like the sky's
# cloud scroll) rather than in NetConfig, which is reserved for sim-affecting values.
const CLOUD_SCROLL_PER_TICK := 0.00012
const WATER_FLOW_PER_TICK := 0.010    # waterfall/pond flow (fast — water moves)
const WIND_SWAY_PER_TICK := 0.004     # foliage sway (slower, gentle breeze)

# Day/night world tint keys (CanvasModulate on the default canvas: world +
# entities + effects; the Sky and HUD CanvasLayers are separate canvases and
# stay untinted). Night blue-shifts and NEVER drops below ~0.5 luminance —
# combat readability beats realism. Same cyclic 4-key blend as sky.gdshader.
const TINT_DAWN := Color(1.04, 0.88, 0.78)
const TINT_NOON := Color(1.0, 1.0, 1.0)
const TINT_DUSK := Color(1.06, 0.82, 0.70)
const TINT_NIGHT := Color(0.52, 0.58, 0.82)

# Entities and tree sprites share one y-sorted Playfield so actors correctly
# walk in front of / behind trees (nested y-sorted nodes flatten into one sort).
@onready var _entities_root: Node2D = $Playfield/Entities
@onready var _trees_root: Node2D = $Playfield/Trees
@onready var _effects: EffectSpawner = $Effects
@onready var _camera: Camera2D = $Camera2D
@onready var _world_tint: CanvasModulate = $WorldTint
@onready var _hud = $HUD  # untyped on purpose: calls hud.gd methods (set_hp/set_debug)
@onready var _sky = $Sky/SkyRect  # procedural day/night sky (world/sky.gd)

func _ready() -> void:
	# Build sprite resources once, here (a normal frame) — never inside a snapshot
	# handler — to avoid the 4.7 native-.new()-in-RPC-frame bug (see CLAUDE.md).
	CharSpriteFrames.warm()
	# Build this lobby's world from the session seed in a normal frame (also
	# prewarms the native RandomNumberGenerator type — see the 4.7 native-.new() note).
	_geometry = WorldGenerator.generate(Session.seed, Session.size)
	Session.geometry = _geometry
	print("[ClientWorld] lobby %d geometry hash = %d" % [Session.lobby_id, _geometry.debug_hash()])
	NetManager.snapshot_received.connect(_on_snapshot)
	NetManager.despawn_received.connect(_on_despawn)
	NetManager.local_player_assigned.connect(_on_local_assigned)
	NetManager.diplomacy_event_received.connect(_on_diplomacy_event)
	NetManager.gems_event_received.connect(_on_gems_event)
	NetManager.orb_event_received.connect(_on_orb_event)
	NetManager.shrine_event_received.connect(_on_shrine_event)
	NetManager.teleport_event_received.connect(_on_teleport_event)
	NetManager.client_connection_failed.connect(func(): push_warning("[ClientWorld] connection failed"))
	_map = TEST_MAP.instantiate() as TestMap
	$World.add_child(_map)
	_map.render(_geometry)
	# Trees live in the y-sorted Playfield (with the entities), not the flat map.
	_map.set_tree_parent(_trees_root)
	_camera.make_current()
	# Dev hook (--shot N): save an in-game screenshot after N seconds, then quit.
	if Session.auto_shot > 0.0:
		_take_shot()
	# Handlers are connected and the scene is live — now ask the server to spawn us.
	# (This gate fixes the old race where assign_local_player could arrive before
	# the client scene was listening.)
	NetManager.client_ready_in_lobby(Session.appearance, Session.faction)

## --shot dev hook: capture a short burst of viewport frames to res://shot*.png
## (snap-confined godot can only write under $HOME, so not the scratchpad) and
## quit. A burst beats a single frame for catching short-lived cast FX.
func _take_shot() -> void:
	await get_tree().create_timer(Session.auto_shot).timeout
	for i in 4:
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		var path := "res://shot.png" if i == 0 else "res://shot%d.png" % i
		var err: int = img.save_png(path)
		print("[ClientWorld] --shot saved %s (err=%d)" % [path, err])
		await get_tree().create_timer(0.3).timeout
	get_tree().quit()

# --- fixed tick: capture input, predict, send -------------------------------
func _physics_process(_delta: float) -> void:
	if local_entity_id == -1 or predicted_state == null:
		return
	var seq := _next_seq
	_next_seq += 1
	var tick := int(round(GameClock.get_estimated_server_tick()))
	var cmd := LocalPlayer.capture_input(seq, tick)
	# Pause menu open: substitute a neutral command (stand still) but KEEP the
	# input stream flowing — seq/acks/reconciliation must never stall.
	if _hud.is_menu_open():
		cmd = InputCommand.create(seq, tick, Vector2.ZERO, 0)
	# Headless test hook (--cast): hold an ability button. OR'd in BEFORE
	# prediction and recording so the predicted command == the sent command.
	if Session.auto_cast_buttons != 0:
		cmd.buttons |= Session.auto_cast_buttons
	# Predict locally for instant response.
	WorldSim.step({predicted_state.id: predicted_state}, {predicted_state.id: cmd}, _geometry, tick, _relations)
	_prediction.record(cmd, predicted_state)
	# Send recent inputs (redundancy against loss).
	NetManager.send_input(_prediction.recent(NetConfig.INPUT_REDUNDANCY))
	if _entities.has(local_entity_id):
		_entities[local_entity_id].apply_state(predicted_state)
	# Bot observability (--cast smoke tests): one compact status line per second,
	# including the nearest monster's/boss's hp so damage skills and the boss
	# replication path are verifiable headless.
	if Session.auto_cast_buttons != 0 and _next_seq % NetConfig.TICK_RATE == 0:
		var mon_hp := -1
		var boss_hp := -1
		var best := INF
		var boss_best := INF
		for id in _entities:
			var n = _entities[id]
			if not (n is GameEntity):
				continue
			var d: float = n.global_position.distance_squared_to(predicted_state.pos)
			if n.state.kind == NetConfig.KIND_MONSTER and d < best:
				best = d
				mon_hp = n.state.hp
			elif n.state.kind == NetConfig.KIND_BOSS and d < boss_best:
				boss_best = d
				boss_hp = n.state.hp
		print("[Bot] hp=%d mon_hp=%d boss_hp=%d entities=%d pos=(%d,%d)" % [predicted_state.hp,
			mon_hp, boss_hp, _entities.size(), int(predicted_state.pos.x), int(predicted_state.pos.y)])

# --- frame: interpolate remotes, follow camera, ping, HUD --------------------
func _process(delta: float) -> void:
	_ping_accum += delta
	if _ping_accum >= NetConfig.PING_INTERVAL_SEC:
		_ping_accum = 0.0
		NetManager.send_ping()

	var render_tick := GameClock.get_render_tick()
	for id in _entities:
		if id == local_entity_id:
			continue
		if _interp.has(id):
			var st: EntityState = _interp[id].sample(render_tick)
			if st != null:
				_entities[id].apply_state(st)

	if local_entity_id != -1 and _entities.has(local_entity_id):
		_camera.global_position = _entities[local_entity_id].global_position

	_update_sky()
	_update_env()
	_update_teleport(delta)
	_update_hud()

# --- day/night sky -----------------------------------------------------------
## Drive the procedural sky from the SYNCHRONIZED clock so every peer in the lobby
## sees the same sun/moon/clouds. Falls back to a fixed mid-morning look during the
## brief pre-sync window so the sky renders immediately instead of black.
func _update_sky() -> void:
	var tod := 0.35
	var phase := 0.0
	if GameClock.is_synced():
		var t := GameClock.get_estimated_server_tick()
		tod = fmod(t, float(NetConfig.DAY_LENGTH_TICKS)) / float(NetConfig.DAY_LENGTH_TICKS)
		phase = fmod(t * CLOUD_SCROLL_PER_TICK, 1.0)
	if Session.debug_tod >= 0.0:
		tod = fmod(Session.debug_tod, 1.0)  # --tod dev override (cosmetic only)
	_sky.set_params(tod, phase, _camera.global_position, get_viewport().get_visible_rect().size)
	# World tint: cyclic 4-key blend (weights sum to 1 — see sky.gdshader wphase).
	var tint: Color = TINT_DAWN * _wphase(tod, 0.0) + TINT_NOON * _wphase(tod, 0.25) \
		+ TINT_DUSK * _wphase(tod, 0.5) + TINT_NIGHT * _wphase(tod, 0.75)
	tint.a = 1.0
	_world_tint.color = tint
	# Night factor (0 = noon, 1 = midnight) brightens the glow layer as the
	# tint darkens the world.
	if _map != null:
		_map.set_night(1.0 - clampf(sin(tod * TAU) * 0.5 + 0.5, 0.0, 1.0))

## Cyclic triangular weight, 1 at center `c`, 0 a quarter-day away (wraps).
func _wphase(t: float, c: float) -> float:
	var d := absf(fposmod(t - c + 0.5, 1.0) - 0.5)
	return maxf(0.0, 1.0 - d * 4.0)

# --- animated water + foliage ------------------------------------------------
## Drive water flow + foliage wind from the SYNCHRONIZED clock (same source as the
## sky) so every peer in the lobby sees identical motion — no extra network traffic.
## Falls back to phase 0 during the brief pre-sync window so they still render.
func _update_env() -> void:
	if _map == null:
		return
	var water := 0.0
	var wind := 0.0
	if GameClock.is_synced():
		var t := GameClock.get_estimated_server_tick()
		water = fmod(t * WATER_FLOW_PER_TICK, 1.0)
		wind = fmod(t * WIND_SWAY_PER_TICK, 1.0)
	_map.set_water_phase(water)
	_map.set_wind_phase(wind)

# --- network handlers --------------------------------------------------------
func _on_snapshot(snapshot: Snapshot) -> void:
	_last_snap_tick = snapshot.server_tick
	if snapshot.server_tick >= _relations_tick:
		if snapshot.relations != _relations:
			_relations = snapshot.relations
			_refresh_diplomacy()
		_relations_tick = snapshot.server_tick
	var seen: Dictionary = {}
	for st in snapshot.entities:
		seen[st.id] = true
		if st.id == local_entity_id:
			_reconcile_local(st)
		else:
			_ensure_remote(st)
			_interp[st.id].push(snapshot.server_tick, st)
	# Transients (projectiles, hazards) absent from a snapshot are gone (snapshots
	# are full-world every tick and unreliable_ordered discards stale ones). This
	# closes the ordering race between the reliable despawn and in-flight
	# unreliable snapshots.
	for id in _entities.keys():
		if seen.has(id):
			continue
		if _entities[id] is Projectile:
			_remove_projectile(id)
		elif _entities[id] is Hazard:
			_remove_transient(id)

func _on_local_assigned(entity_id: int) -> void:
	local_entity_id = entity_id
	if _entities.has(entity_id):
		# Already created as a remote from an earlier snapshot — promote it.
		var seed_state: EntityState = _interp[entity_id].latest() if _interp.has(entity_id) else _entities[entity_id].state
		predicted_state = seed_state.clone()
		_promote_to_local()
	print("[ClientWorld] local entity = %d" % entity_id)

## Reliable diplomacy notification: merge relations latest-wins against the
## unreliable_ordered snapshot stream (cross-mode ordering is undefined), track
## pending proposals for the panel, and toast the event.
func _on_diplomacy_event(a_faction: int, b_faction: int, event_kind: int, relations: int, server_tick: int) -> void:
	if server_tick >= _relations_tick:
		_relations = relations
		_relations_tick = server_tick
	var pi := FactionDefs.pair_index(a_faction, b_faction)
	if event_kind == FactionDefs.EVENT_ALLIANCE_PROPOSED:
		_pending_proposals[pi] = a_faction
	else:
		_pending_proposals.erase(pi)
	_hud.show_toast(_diplomacy_toast_text(a_faction, b_faction, event_kind))
	_refresh_diplomacy()

## Drive the teleport cast bar off the synced clock, and run the --auto-tp bot
## (headless smoke: request the first allowed far destination every ~2 s and
## print every event, so the whole loop is verifiable without a display).
func _update_teleport(delta: float) -> void:
	if _tp_cast_start_tick >= 0.0:
		var elapsed := GameClock.get_estimated_server_tick() - _tp_cast_start_tick
		var frac := elapsed / float(TeleportDefs.TP_CAST_TICKS)
		var remain := (float(TeleportDefs.TP_CAST_TICKS) - elapsed) / float(NetConfig.TICK_RATE)
		_hud.set_cast_progress(frac, remain)
	if Session.auto_tp and predicted_state != null:
		_auto_tp_accum += delta
		if _auto_tp_accum >= 2.0:
			_auto_tp_accum = 0.0
			if _tp_cast_start_tick < 0.0:
				_request_auto_tp()

## Pick the first destination the shared rules allow that is a real trip
## (>= 200 px away) — villages first, then the neutral mid markets.
func _request_auto_tp() -> void:
	for i in _geometry.villages.size():
		if TeleportDefs.can_teleport_to(_geometry, predicted_state.faction, TeleportDefs.DEST_VILLAGE, i) \
		and predicted_state.pos.distance_to(_geometry.villages[i]) >= 200.0:
			NetManager.client_request_teleport(TeleportDefs.DEST_VILLAGE, i)
			return
	for i in _geometry.merchants.size():
		if TeleportDefs.can_teleport_to(_geometry, predicted_state.faction, TeleportDefs.DEST_MERCHANT, i) \
		and predicted_state.pos.distance_to(_geometry.merchants[i]) >= 200.0:
			NetManager.client_request_teleport(TeleportDefs.DEST_MERCHANT, i)
			return

## Reliable teleport notification. `data` = remaining cooldown ticks (only
## meaningful on COMPLETED / REJECT_COOLDOWN — authoritative, never guessed).
func _on_teleport_event(event: int, data: int) -> void:
	var est := GameClock.get_estimated_server_tick()
	match event:
		TeleportDefs.EVENT_STARTED:
			_tp_cast_start_tick = est
			_hud.begin_cast()
		TeleportDefs.EVENT_COMPLETED:
			_tp_cast_start_tick = -1.0
			_tp_ready_tick = est + float(data)
			_hud.end_cast()
		TeleportDefs.REJECT_COOLDOWN:
			_tp_ready_tick = est + float(data)
		_:
			# Every cancel/reject ends any running cast bar.
			_tp_cast_start_tick = -1.0
			_hud.end_cast()
	if Session.auto_tp:
		print("[TP] event=%d data=%d pos=(%d,%d)" % [event, data,
			int(predicted_state.pos.x) if predicted_state != null else 0,
			int(predicted_state.pos.y) if predicted_state != null else 0])
	_hud.show_toast(_teleport_toast_text(event))

func _teleport_toast_text(event: int) -> String:
	match event:
		TeleportDefs.EVENT_STARTED:
			return "Teleporting… stand still"
		TeleportDefs.EVENT_COMPLETED:
			return "Teleport complete"
		TeleportDefs.EVENT_CANCELLED_MOVED:
			return "Teleport cancelled — you moved"
		TeleportDefs.EVENT_CANCELLED_DAMAGED:
			return "Teleport cancelled — you took damage"
		TeleportDefs.EVENT_CANCELLED_DEAD:
			return "Teleport cancelled"
		TeleportDefs.REJECT_COOLDOWN:
			return "Teleport not ready yet"
		TeleportDefs.REJECT_RANGE:
			return "Too far from a waypoint"
		TeleportDefs.REJECT_DENIED:
			return "You can't travel there"
		TeleportDefs.REJECT_BUSY:
			return "Already teleporting"
		TeleportDefs.REJECT_DEAD:
			return "You are dead"
	return ""

## Reliable pickup-state notification: hide a taken orb/cache marker, or show
## it again on respawn. The gem award itself arrives via gems_event.
func _on_orb_event(kind: int, index: int, taken: bool) -> void:
	if _map != null:
		_map.set_pickup_taken(kind, index, taken)

func _on_shrine_event(faction: int, _island: int) -> void:
	_hud.show_toast("%s captured a shrine!" % FactionPalette.name_of(faction))

## Reliable gems notification: boss payouts, purchase results and rejections.
## The balance ships in every event, so the display can never drift.
func _on_gems_event(balance: int, delta: int, reason: int, item_id: int) -> void:
	print("[Gems] balance=%d delta=%d reason=%d item=%d" % [balance, delta, reason, item_id])
	_gems = balance
	_hud.set_gems(_gems)
	_hud.show_toast(_gems_toast_text(delta, reason, item_id))
	_hud.refresh_shop(predicted_state.upgrades if predicted_state != null else 0, _gems)

func _gems_toast_text(delta: int, reason: int, item_id: int) -> String:
	match reason:
		UpgradeDefs.GEMS_AWARD_BOSS:
			return "+%d gems — raid boss defeated!" % delta
		UpgradeDefs.GEMS_AWARD_MONSTER:
			return "+%d gems" % delta
		UpgradeDefs.GEMS_PURCHASE_OK:
			var item := ShopPanel.ITEM_NAMES[item_id] if item_id >= 0 and item_id < UpgradeDefs.ITEM_COUNT else "?"
			return "Bought %s (%d gems)" % [item, delta]
		UpgradeDefs.GEMS_REJECT_RANGE:
			return "Too far from a merchant"
		UpgradeDefs.GEMS_REJECT_FUNDS:
			return "Not enough gems"
		UpgradeDefs.GEMS_REJECT_MAXED:
			return "Already owned or maxed"
		UpgradeDefs.GEMS_GRANT:
			return "+%d gems" % delta
		UpgradeDefs.GEMS_AWARD_ORB:
			return "+%d gems — orb collected" % delta
		UpgradeDefs.GEMS_AWARD_CACHE:
			return "+%d gems — hidden cache found!" % delta
		UpgradeDefs.GEMS_AWARD_SHRINE:
			return "+%d gems — shrine captured!" % delta
	return ""

func _diplomacy_toast_text(a_faction: int, b_faction: int, event_kind: int) -> String:
	var an := FactionPalette.name_of(a_faction)
	var bn := FactionPalette.name_of(b_faction)
	match event_kind:
		FactionDefs.EVENT_RIVALRY_DECLARED:
			return "%s declared RIVALRY with %s!" % [an, bn]
		FactionDefs.EVENT_ALLIANCE_PROPOSED:
			return "%s proposes an alliance to %s" % [an, bn]
		FactionDefs.EVENT_ALLIANCE_FORMED:
			return "%s and %s are now ALLIED" % [an, bn]
		FactionDefs.EVENT_ALLIANCE_BROKEN:
			return "%s broke the alliance with %s" % [an, bn]
	return ""

## The panel shows relations vs OUR faction — use the authoritative one from the
## predicted state (the server may have auto-assigned differently from the saved
## pick), falling back to the saved pick before the first reconcile.
func _refresh_diplomacy() -> void:
	var my_faction := predicted_state.faction if predicted_state != null else Session.faction
	_hud.refresh_diplomacy(my_faction, Session.faction_count, _relations, _pending_proposals)

func _on_despawn(entity_id: int) -> void:
	if _entities.has(entity_id) and _entities[entity_id] is Projectile:
		_remove_projectile(entity_id)
		return
	if _entities.has(entity_id) and _entities[entity_id] is Hazard:
		_remove_transient(entity_id)
		return
	if _entities.has(entity_id):
		_entities[entity_id].queue_free()
		_entities.erase(entity_id)
	_interp.erase(entity_id)
	if entity_id == local_entity_id:
		local_entity_id = -1
		predicted_state = null

## Free a projectile node with a small impact flash where it last rendered.
func _remove_projectile(entity_id: int) -> void:
	var node: Node2D = _entities[entity_id]
	_effects.spawn(EffectIds.BOLT_IMPACT, node.global_position, Vector2.DOWN)
	node.queue_free()
	_entities.erase(entity_id)
	_interp.erase(entity_id)

## Free a hazard node with no flash — the zone already faded out via its TTL.
func _remove_transient(entity_id: int) -> void:
	_entities[entity_id].queue_free()
	_entities.erase(entity_id)
	_interp.erase(entity_id)

# --- prediction / reconciliation --------------------------------------------
func _reconcile_local(server_state: EntityState) -> void:
	if predicted_state == null:
		# First authoritative state for our entity: adopt it and spawn the node.
		predicted_state = server_state.clone()
		_promote_to_local()
		_refresh_diplomacy()  # now we know our authoritative faction
		return
	var before := predicted_state.pos
	predicted_state.copy_from(server_state)
	_prediction.ack(server_state.last_input_seq)
	# Replay inputs the server hasn't processed yet on top of authority.
	for cmd in _prediction.remaining_cmds():
		WorldSim.step({predicted_state.id: predicted_state}, {predicted_state.id: cmd}, _geometry, 0, _relations)
	reconcile_error_px = before.distance_to(predicted_state.pos)
	if _entities.has(local_entity_id):
		_entities[local_entity_id].apply_state(predicted_state)

# --- entity node management --------------------------------------------------
func _ensure_remote(st: EntityState) -> void:
	if not _interp.has(st.id):
		_interp[st.id] = InterpolationBuffer.new()
	if _entities.has(st.id):
		return
	# Untyped on purpose: GameEntity and Projectile share the setup/apply_state
	# surface without a common base class.
	var node = _make_node(st.kind)
	node.setup(st.clone(), GameEntity.MODE_REMOTE)
	if node is GameEntity:  # projectiles draw themselves and emit no effects
		_effects.bind(node)
	_entities_root.add_child(node)
	_entities[st.id] = node
	if st.kind == NetConfig.KIND_PLAYER:
		print("[ClientWorld] remote player entity %d appearance=%d" % [st.id, st.appearance])

func _promote_to_local() -> void:
	var node: GameEntity
	if _entities.has(local_entity_id):
		node = _entities[local_entity_id]
	else:
		node = _make_node(predicted_state.kind) as GameEntity  # local is always a player
		_effects.bind(node)
		_entities_root.add_child(node)
		_entities[local_entity_id] = node
	node.setup(predicted_state, GameEntity.MODE_LOCAL)
	_interp.erase(local_entity_id)  # local is predicted, never interpolated

func _make_node(kind: int) -> Node2D:
	if kind == NetConfig.KIND_PROJECTILE:
		return PROJECTILE_SCENE.instantiate() as Node2D
	if kind == NetConfig.KIND_HAZARD:
		return HAZARD_SCENE.instantiate() as Node2D
	# Bosses reuse the monster shell: GameEntity branches on state.kind for the
	# 3x scale, kit tint, big HP bar and windup telegraphs.
	var scene := MONSTER_SCENE if (kind == NetConfig.KIND_MONSTER or kind == NetConfig.KIND_BOSS) else PLAYER_SCENE
	return scene.instantiate() as Node2D

# --- HUD ---------------------------------------------------------------------
func _update_hud() -> void:
	if local_entity_id != -1 and predicted_state != null:
		_hud.set_hp(predicted_state.hp, EntityDefs.max_hp_of(predicted_state))  # VIGOR-aware
		_hud.set_ability_state(predicted_state)
		# Merchant proximity drives the "E Shop" hint (predicted pos; the server
		# revalidates against its own on purchase). Merchants are one per island.
		var in_range := false
		for m in _geometry.merchants:
			if predicted_state.pos.distance_to(m) <= UpgradeDefs.MERCHANT_RANGE:
				in_range = true
				break
		_hud.set_shop_hint(in_range)
		# Waypoint proximity drives the "T Travel" hint the same way (predicted
		# pos; Lobby.apply_teleport revalidates against the authoritative one).
		_hud.set_travel_hint(TeleportDefs.near_waypoint(_geometry, predicted_state.pos))
		_hud.refresh_waypoints(_geometry, predicted_state.faction,
			int(maxf(0.0, _tp_ready_tick - GameClock.get_estimated_server_tick())))
		# A bought upgrade lands via snapshot; re-feed the shop when it changes.
		if predicted_state.upgrades != _last_upgrades:
			_last_upgrades = predicted_state.upgrades
			_hud.refresh_shop(predicted_state.upgrades, _gems)
	_update_boss_bar()
	_hud.set_debug(NetDebug.format({
		"synced": GameClock.is_synced(),
		"rtt_ms": GameClock.rtt_ms,
		"est_tick": GameClock.get_estimated_server_tick(),
		"snap_tick": _last_snap_tick,
		"render_tick": GameClock.get_render_tick(),
		"recon_err": reconcile_error_px,
		"unacked": _prediction.size(),
		"entities": _entities.size(),
	}))

## Raid frame: the nearest living boss within BOSS_BAR_RANGE of our player.
func _update_boss_bar() -> void:
	var boss: GameEntity = null
	var best := BOSS_BAR_RANGE * BOSS_BAR_RANGE
	if predicted_state != null:
		for id in _entities:
			var n = _entities[id]
			if n is GameEntity and n.state.kind == NetConfig.KIND_BOSS and n.state.is_alive():
				var d: float = n.global_position.distance_squared_to(predicted_state.pos)
				if d < best:
					best = d
					boss = n
	if boss != null:
		# Tiered max (danger tier rides upgrades): outer bosses show a smaller pool.
		_hud.set_boss_bar(BossDefs.kit_name(boss.state.appearance), boss.state.hp, EntityDefs.max_hp_of(boss.state), boss.state.appearance)
	else:
		_hud.hide_boss_bar()
