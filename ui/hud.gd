extends CanvasLayer
## HUD overlay: health + gems readouts, toggleable network-debug panel (F3),
## faction diplomacy panel (P), merchant shop panel (E near a stall), waypoint
## travel panel (T near a waypoint) + teleport cast bar, the ESC pause menu and
## transient event toasts.

const TOAST_HOLD_SEC := 2.2
const TOAST_FADE_SEC := 0.8

@onready var hp_label: Label = $HpLabel
@onready var gems_label: Label = $GemsLabel
@onready var debug_label: Label = $DebugLabel
@onready var _hotbar: Hotbar = $Hotbar
@onready var _boss_bar: BossBar = $BossBar
@onready var _diplomacy: DiplomacyPanel = $DiplomacyPanel
@onready var _shop: ShopPanel = $ShopPanel
@onready var _shop_hint: Label = $ShopHint
@onready var _waypoints: WaypointPanel = $WaypointPanel
@onready var _travel_hint: Label = $TravelHint
@onready var _cast_bar: CastBar = $CastBar
@onready var _toasts: VBoxContainer = $Toasts
@onready var _pause: PauseMenu = $PauseMenu

var _show_debug: bool = true
var _shop_in_range: bool = false
var _travel_in_range: bool = false

func _ready() -> void:
	# Pixel-font theme on every HUD Control (a CanvasLayer can't inherit one).
	UiTheme.apply(self)
	# The panels only emit; requests go straight out (server revalidates).
	_diplomacy.action_pressed.connect(
		func(target_faction: int, action: int): NetManager.client_diplomacy_action(target_faction, action))
	_shop.purchase_pressed.connect(
		func(item_id: int): NetManager.client_shop_purchase(item_id))
	_waypoints.travel_pressed.connect(
		func(dest_kind: int, dest_index: int): NetManager.client_request_teleport(dest_kind, dest_index))
	_pause.leave_pressed.connect(_on_leave_lobby)
	_pause.quit_pressed.connect(func(): get_tree().quit())

func set_hp(current: int, maximum: int) -> void:
	hp_label.text = "HP  %d / %d" % [maxi(0, current), maximum]

func set_gems(n: int) -> void:
	gems_label.text = "GEMS  %d" % n

## Called every frame by ClientWorld with the predicted merchant proximity.
## Leaving range auto-closes the shop (the server would reject buys anyway).
func set_shop_hint(in_range: bool) -> void:
	_shop_in_range = in_range
	if not in_range and _shop.visible:
		_shop.close()
	_shop_hint.visible = in_range and not _shop.visible and not _pause.visible

func refresh_shop(upgrades: int, gems: int) -> void:
	_shop.refresh(upgrades, gems)

## Called every frame by ClientWorld with the predicted waypoint proximity.
## Leaving range auto-closes the panel (the server would reject anyway).
func set_travel_hint(in_range: bool) -> void:
	_travel_in_range = in_range
	if not in_range and _waypoints.visible:
		_waypoints.close()
	_travel_hint.visible = in_range and not _waypoints.visible and not _pause.visible

func refresh_waypoints(geometry: WorldGeometry, my_faction: int, ready_in_ticks: int) -> void:
	_waypoints.refresh(geometry, my_faction, ready_in_ticks)

# Teleport cast bar forwarders (driven by ClientWorld off the synced clock).
func begin_cast() -> void:
	_cast_bar.begin()

func set_cast_progress(frac: float, remaining_sec: float) -> void:
	_cast_bar.set_progress(frac, remaining_sec)

func end_cast() -> void:
	_cast_bar.end()

func set_ability_state(s: EntityState) -> void:
	_hotbar.set_ability_state(s)

func set_boss_bar(boss_name: String, hp: int, max_hp: int, kit: int = 0) -> void:
	_boss_bar.show_boss(boss_name, hp, max_hp, kit)

func hide_boss_bar() -> void:
	_boss_bar.hide_boss()

func set_debug(text: String) -> void:
	debug_label.text = text

func refresh_diplomacy(my_faction: int, faction_count: int, relations: int, pending: Dictionary) -> void:
	_diplomacy.refresh(my_faction, faction_count, relations, pending)

## Transient top-center notification (diplomacy events): stacks, fades, frees.
func show_toast(text: String) -> void:
	if text.is_empty():
		return
	var lab := Label.new()
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toasts.add_child(lab)
	var tw := lab.create_tween()
	tw.tween_interval(TOAST_HOLD_SEC)
	tw.tween_property(lab, "modulate:a", 0.0, TOAST_FADE_SEC)
	tw.tween_callback(lab.queue_free)

## Whether the pause menu is open. Read by ClientWorld every tick: while open,
## the local player sends neutral inputs (the sim never pauses — server rules).
func is_menu_open() -> bool:
	return _pause.visible

func _on_leave_lobby() -> void:
	NetManager.client_leave_lobby()
	# We bypass main_menu._ready() (which normally clears the session), so clear
	# here; clear() keeps appearance/faction. The connection stays open — the
	# browser reuses it.
	Session.clear()
	get_tree().change_scene_to_file("res://scenes/lobby_browser.tscn")

func _unhandled_input(event: InputEvent) -> void:
	# ESC closes the topmost panel first; with nothing open it opens the menu.
	if event.is_action_pressed("toggle_menu"):
		if _shop.visible:
			_shop.close()
			_shop_hint.visible = _shop_in_range
		elif _waypoints.visible:
			_waypoints.close()
			_travel_hint.visible = _travel_in_range
		elif _diplomacy.visible:
			_diplomacy.close()
		elif _pause.visible:
			_pause.escape()
		else:
			_pause.open()
		return
	# The pause menu is modal: swallow the other panel/debug toggles while open.
	if _pause.visible:
		return
	if event.is_action_pressed("toggle_debug"):
		_show_debug = not _show_debug
		debug_label.visible = _show_debug
	if event.is_action_pressed("toggle_diplomacy"):
		_diplomacy.toggle()
	# E toggles the shop only near a merchant (closing works from anywhere).
	if event.is_action_pressed("interact") and (_shop_in_range or _shop.visible):
		_shop.toggle()
		_shop_hint.visible = _shop_in_range and not _shop.visible
	# T toggles the waypoint panel only near a waypoint (closing from anywhere).
	if event.is_action_pressed("travel") and (_travel_in_range or _waypoints.visible):
		_waypoints.toggle()
		_travel_hint.visible = _travel_in_range and not _waypoints.visible
