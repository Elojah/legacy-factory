extends Control
## Lobby browser: connects to the dedicated server, lists its lobbies, and lets the
## player create a new one (size preset + faction count + name) or join a selected
## one. Entering the game on a successful create/join is handled centrally by
## Bootstrap (it listens for lobby_join_accepted_sig and swaps to the game scene),
## so this screen only sends requests and surfaces the list / errors.

var _lobbies: Array = []  # cached list of lobby-info dictionaries

@onready var _list: ItemList = $VBox/List
@onready var _size_opt: OptionButton = $VBox/CreateRow/SizeOption
@onready var _factions_opt: OptionButton = $VBox/CreateRow/FactionOption
@onready var _name_edit: LineEdit = $VBox/CreateRow/NameEdit
@onready var _status: Label = $VBox/Status

func _ready() -> void:
	theme = UiTheme.get_theme()
	_size_opt.add_item("Small (2p)", WorldGenerator.SIZE_SMALL)
	_size_opt.add_item("Medium (4p)", WorldGenerator.SIZE_MEDIUM)
	_size_opt.add_item("Large (20p)", WorldGenerator.SIZE_LARGE)
	_size_opt.selected = 1
	for fc in range(FactionDefs.MIN_LOBBY_FACTIONS, FactionDefs.MAX_LOBBY_FACTIONS + 1):
		_factions_opt.add_item("%d factions" % fc, fc)
	_factions_opt.selected = 0
	$VBox/ListRow/Refresh.pressed.connect(_refresh)
	$VBox/ListRow/Join.pressed.connect(_on_join)
	$VBox/CreateRow/Create.pressed.connect(_on_create)
	$VBox/Back.pressed.connect(_on_back)
	NetManager.lobby_list_received.connect(_on_list)
	NetManager.lobby_join_rejected_sig.connect(_on_rejected)
	NetManager.client_connected.connect(_on_connected)
	NetManager.client_connection_failed.connect(_on_failed)
	# Connect to the server if the menu hasn't already (Play -> here is the usual path).
	if NetManager.is_connected_to_server():
		_refresh()
	else:
		_status.text = "Connecting to %s:%d..." % [NetManager.connect_ip, NetManager.connect_port]
		NetManager.connect_to_server(NetManager.connect_ip, NetManager.connect_port)

func _on_connected() -> void:
	_status.text = "Connected."
	_refresh()

func _on_failed() -> void:
	_status.text = "Connection failed — is the server running?"

func _refresh() -> void:
	if NetManager.is_connected_to_server():
		NetManager.client_request_lobby_list()

func _on_list(list: Array) -> void:
	_lobbies = list
	_list.clear()
	for lob in list:
		_list.add_item("#%d  %s  [%d/%d]  %d factions" % [lob["id"], lob["name"],
			lob["players"], lob["max"], lob.get("factions", FactionDefs.MIN_LOBBY_FACTIONS)])
	_status.text = "%d lobbies" % list.size() if not list.is_empty() else "No lobbies yet — create one."

func _on_create() -> void:
	var sz: int = _size_opt.get_item_id(_size_opt.selected)
	var fc: int = _factions_opt.get_item_id(_factions_opt.selected)
	NetManager.client_create_lobby(sz, fc, _name_edit.text)
	_status.text = "Creating lobby..."

func _on_join() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		_status.text = "Select a lobby to join."
		return
	var lob: Dictionary = _lobbies[sel[0]]
	NetManager.client_join_lobby(lob["id"])
	_status.text = "Joining lobby %d..." % lob["id"]

func _on_rejected(reason: int) -> void:
	match reason:
		NetManager.REJECT_FULL: _status.text = "That lobby is full."
		NetManager.REJECT_NOT_FOUND: _status.text = "That lobby no longer exists."
		_: _status.text = "Could not join (reason %d)." % reason
	_refresh()

func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
