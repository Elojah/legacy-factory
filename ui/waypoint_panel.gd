class_name WaypointPanel extends PanelContainer
## Waypoint travel panel (opened with T near a village or merchant stall). Rows
## are the destinations TeleportDefs.can_teleport_to allows — own-faction home
## villages + neutral mid markets — so the panel greys out exactly what the
## server would reject. Pure UI: state is fed by ClientWorld through
## HUD.refresh_waypoints and requests surface via travel_pressed; the server
## (Lobby.apply_teleport) revalidates everything anyway.

signal travel_pressed(dest_kind: int, dest_index: int)

var _geometry: WorldGeometry = null
var _my_faction: int = 0
var _ready_in_ticks: int = 0
var _title: Label
var _rows: VBoxContainer
var _built_faction: int = -1
var _travel_buttons: Array = []   # Button nodes, disabled while cooling down

func _ready() -> void:
	visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_title)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	box.add_child(_rows)

## Fed every frame by ClientWorld (like the shop's refresh, plus the live
## cooldown countdown). Cheap while visible: only the title text and the
## buttons' disabled state update in place — rows are rebuilt on open only
## (geometry and faction never change mid-lobby).
func refresh(geometry: WorldGeometry, my_faction: int, ready_in_ticks: int) -> void:
	_geometry = geometry
	_my_faction = my_faction
	_ready_in_ticks = maxi(0, ready_in_ticks)
	if not visible:
		return
	if _built_faction != _my_faction:
		_rebuild()
	_update_readiness()

func toggle() -> void:
	visible = not visible
	if visible:
		_rebuild()

func close() -> void:
	visible = false

func _rebuild() -> void:
	_built_faction = _my_faction
	_travel_buttons.clear()
	for c in _rows.get_children():
		c.queue_free()
	if _geometry == null:
		return
	var home := 0
	for i in _geometry.villages.size():
		if TeleportDefs.can_teleport_to(_geometry, _my_faction, TeleportDefs.DEST_VILLAGE, i):
			home += 1
			_rows.add_child(_make_row("Home village %d" % home, TeleportDefs.DEST_VILLAGE, i))
	var market := 0
	for i in _geometry.merchants.size():
		if TeleportDefs.can_teleport_to(_geometry, _my_faction, TeleportDefs.DEST_MERCHANT, i):
			market += 1
			_rows.add_child(_make_row("Neutral market %d" % market, TeleportDefs.DEST_MERCHANT, i))
	_update_readiness()

func _update_readiness() -> void:
	if _ready_in_ticks > 0:
		_title.text = "WAYPOINT  —  ready in %s" % _fmt_ticks(_ready_in_ticks)
	else:
		_title.text = "WAYPOINT  —  ready"
	for b in _travel_buttons:
		b.disabled = _ready_in_ticks > 0

func _make_row(dest_name: String, dest_kind: int, dest_index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(190, 0)
	name_label.text = dest_name
	row.add_child(name_label)
	var btn := Button.new()
	btn.text = "Travel"
	btn.pressed.connect(func(): travel_pressed.emit(dest_kind, dest_index))
	row.add_child(btn)
	_travel_buttons.append(btn)
	return row

func _fmt_ticks(ticks: int) -> String:
	@warning_ignore("integer_division")
	var secs: int = (ticks + NetConfig.TICK_RATE - 1) / NetConfig.TICK_RATE
	@warning_ignore("integer_division")
	return "%d:%02d" % [secs / 60, secs % 60]
