extends Node
## Bootstrap — runs first (last app autoload; NetConfig/GameClock/NetManager/Session
## already exist). Picks the role from CLI args, starts networking, and drives the
## client into a lobby. The server hosts and loads the manager scene. The client
## connects and then either follows a CLI fast-path (--auto-create/--auto-join, for
## headless testing) or shows the main menu; entering the game scene happens
## centrally when the server accepts a create/join (lobby_join_accepted_sig).
##
## Usage (args after a bare `--`):
##   --server [--port N] [--grant-gems N]
##   --client [--connect IP] [--port N] [--lag MS] [--jitter MS] [--loss FRAC]
##            [--auto-create small|medium|large] [--auto-join LOBBY_ID] [--name NAME]
##            [--class warrior|mage|archer]
##            [--cast melee|bolt|dash|heal|slam|nova|volley] [--auto-tp]
##            [--faction 1..4] [--factions 2..4]
## With no role flag: headless display => server, otherwise => client.
## --faction overrides the saved character's faction pick; --factions sets the
## faction count of an --auto-create'd lobby. --grant-gems seeds every spawned
## player with N gems (dev/test: the merchant loop without farming a boss).

# Server-only dev/test flag, read by ServerWorld on each player spawn.
var grant_gems: int = 0

var _auto_create: bool = false
var _auto_join: bool = false
var _auto_size: int = WorldGenerator.SIZE_MEDIUM
var _auto_factions: int = FactionDefs.MIN_LOBBY_FACTIONS
var _auto_lobby_id: int = 0
var _auto_name: String = "auto"

func _ready() -> void:
	# Defer one frame so the SceneTree's current_scene is established before we
	# swap it (we are an autoload; the main scene may not be set yet).
	await get_tree().process_frame
	_start()

func _start() -> void:
	var args := _parse_args()
	# Dev hook: `--preview` renders the art on a static scene (no networking).
	if args.has("preview"):
		get_tree().change_scene_to_file("res://tools/art_preview.tscn")
		print("[Bootstrap] role=preview")
		return
	var role: String = args.get("role", "")
	if role.is_empty():
		role = "server" if DisplayServer.get_name() == "headless" else "client"

	if role == "server":
		grant_gems = maxi(0, int(args.get("grant_gems", "0")))
		var sport := int(args.get("port", str(NetConfig.DEFAULT_PORT)))
		if NetManager.host_server(sport):
			get_tree().change_scene_to_file("res://scenes/server_root.tscn")
		print("[Bootstrap] role=server")
		return

	# --- client ---
	# Apply persisted display/audio settings before any scene shows (client only:
	# the server branch returned above; apply_fullscreen no-ops headless).
	GameSettings.load_cfg()
	GameSettings.apply()
	NetManager.configure_latency(
		float(args.get("lag", "0")),
		float(args.get("jitter", "0")),
		float(args.get("loss", "0")))
	NetManager.connect_ip = args.get("connect", NetConfig.DEFAULT_CONNECT_IP)
	NetManager.connect_port = int(args.get("port", str(NetConfig.DEFAULT_PORT)))
	_auto_create = args.has("auto_create")
	_auto_join = args.has("auto_join")
	_auto_size = _parse_size(args.get("auto_create", "medium"))
	_auto_factions = clampi(int(args.get("factions", str(FactionDefs.MIN_LOBBY_FACTIONS))),
		FactionDefs.MIN_LOBBY_FACTIONS, FactionDefs.MAX_LOBBY_FACTIONS)
	_auto_lobby_id = int(args.get("auto_join", "0"))
	_auto_name = args.get("name", "auto")
	# Test hook: hold one ability button forever (headless skill smoke tests).
	Session.auto_cast_buttons = _parse_cast(args.get("cast", ""))
	# Test hook: request waypoint travel on a loop (headless teleport smoke test).
	Session.auto_tp = args.has("auto_tp")
	# Load the saved character (default look if none); --class overrides just the
	# class subfield so headless tests can exercise the appearance sync.
	Session.load_character()
	if args.has("class"):
		Session.appearance = Appearance.encode(
			_parse_class(args.get("class", "")),
			Appearance.hair_style_of(Session.appearance),
			Appearance.hair_color_of(Session.appearance),
			Appearance.skin_tone_of(Session.appearance))
	# --faction overrides just the saved faction pick (headless faction tests).
	if args.has("faction"):
		Session.faction = clampi(int(args.get("faction", "1")),
			FactionDefs.FACTION_FIRST, FactionDefs.FACTION_COUNT)
	# Central scene transitions: accepted -> enter game; rejected -> warn. Wired for
	# every client path (UI and auto), since the server's accept drives the swap.
	NetManager.lobby_join_accepted_sig.connect(_on_join_accepted)
	NetManager.lobby_join_rejected_sig.connect(_on_join_rejected)

	if _auto_create or _auto_join:
		# Headless/CLI fast-path: connect now and drive the handshake (no UI).
		NetManager.client_connected.connect(_on_client_connected)
		if NetManager.connect_to_server(NetManager.connect_ip, NetManager.connect_port):
			print("[Bootstrap] role=client (auto, connecting)")
	elif args.has("browser"):
		# Dev shortcut: skip the menu, go straight to the lobby browser.
		get_tree().change_scene_to_file("res://scenes/lobby_browser.tscn")
		print("[Bootstrap] role=client (browser)")
	elif Session.has_saved_character():
		# Normal client: show the menu; the browser connects when Play is pressed.
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		print("[Bootstrap] role=client (menu)")
	else:
		# First launch (no saved character): open the creator once; Save leads to
		# the menu. Auto/headless and --browser paths skip this on purpose.
		get_tree().change_scene_to_file("res://scenes/character_creator.tscn")
		print("[Bootstrap] role=client (character creator, first run)")

func _on_client_connected() -> void:
	if _auto_create:
		NetManager.client_create_lobby(_auto_size, _auto_factions, _auto_name)
	elif _auto_join:
		NetManager.client_join_lobby(_auto_lobby_id)
	else:
		# Phase 2 default: drop into a fresh medium lobby so a plain --client still
		# reaches a game. Phase 3 replaces this with the main menu.
		NetManager.client_create_lobby(WorldGenerator.SIZE_MEDIUM, FactionDefs.MIN_LOBBY_FACTIONS, "auto")

func _on_join_accepted(lobby_id: int, seed: int, size: int, factions: int) -> void:
	Session.set_lobby(lobby_id, seed, size, factions)
	get_tree().change_scene_to_file("res://scenes/client_root.tscn")
	print("[Bootstrap] entering lobby %d" % lobby_id)

func _on_join_rejected(reason: int) -> void:
	push_warning("[Bootstrap] lobby join rejected (reason %d)" % reason)

func _parse_size(s: String) -> int:
	match s.to_lower():
		"small": return WorldGenerator.SIZE_SMALL
		"large": return WorldGenerator.SIZE_LARGE
		_: return WorldGenerator.SIZE_MEDIUM

func _parse_class(s: String) -> int:
	match s.to_lower():
		"mage": return Appearance.CLASS_MAGE
		"archer": return Appearance.CLASS_ARCHER
		_: return Appearance.CLASS_WARRIOR

func _parse_cast(s: String) -> int:
	match s.to_lower():
		"melee": return NetConfig.BTN_ATTACK
		"bolt": return NetConfig.BTN_BOLT
		"dash": return NetConfig.BTN_DASH
		"heal": return NetConfig.BTN_HEAL
		"slam": return NetConfig.BTN_SLAM
		# Merchant-unlockables: cast nothing until bought (the sim gate itself).
		"nova": return NetConfig.BTN_NOVA
		"volley": return NetConfig.BTN_VOLLEY
		_: return 0

func _parse_args() -> Dictionary:
	var out := {}
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		match a[i]:
			"--server": out["role"] = "server"
			"--client": out["role"] = "client"
			"--preview": out["preview"] = true
			"--connect":
				i += 1
				if i < a.size(): out["connect"] = a[i]
			"--port":
				i += 1
				if i < a.size(): out["port"] = a[i]
			"--lag":
				i += 1
				if i < a.size(): out["lag"] = a[i]
			"--jitter":
				i += 1
				if i < a.size(): out["jitter"] = a[i]
			"--loss":
				i += 1
				if i < a.size(): out["loss"] = a[i]
			"--auto-create":
				i += 1
				if i < a.size(): out["auto_create"] = a[i]
			"--auto-join":
				i += 1
				if i < a.size(): out["auto_join"] = a[i]
			"--name":
				i += 1
				if i < a.size(): out["name"] = a[i]
			"--class":
				i += 1
				if i < a.size(): out["class"] = a[i]
			"--cast":
				i += 1
				if i < a.size(): out["cast"] = a[i]
			"--auto-tp": out["auto_tp"] = true
			"--faction":
				i += 1
				if i < a.size(): out["faction"] = a[i]
			"--factions":
				i += 1
				if i < a.size(): out["factions"] = a[i]
			"--grant-gems":
				i += 1
				if i < a.size(): out["grant_gems"] = a[i]
			"--browser": out["browser"] = true
		i += 1
	return out
