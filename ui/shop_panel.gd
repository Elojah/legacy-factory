class_name ShopPanel extends PanelContainer
## Village merchant shop (opened with E near a merchant stall). One row per
## purchasable item: the 5 base-skill upgrade tracks, the 2 unlockable skills
## and the 3 passives. Pure UI: state (upgrades bitfield + gem balance) is fed
## by ClientWorld through HUD.refresh_shop and buys surface via purchase_pressed;
## the server (Lobby.apply_purchase) revalidates everything anyway.

signal purchase_pressed(item_id: int)

## Client-side item cosmetics (indexed by UpgradeDefs.ITEM_*); costs, levels
## and availability rules come from UpgradeDefs — never duplicated here.
const ITEM_NAMES: Array[String] = [
	"Melee", "Bolt", "Dash", "Heal", "Slam",
	"Nova", "Volley", "Vigor", "Swift", "Focus",
]
const ITEM_BLURBS: Array[String] = [
	"+15% damage per level", "+15% damage per level", "-15% cooldown per level",
	"+15% healing per level", "+15% damage per level",
	"Unlock: AoE burst (key 6)", "Unlock: 3-bolt spread (key 7)",
	"Passive: +25 max HP", "Passive: +12% move speed", "Passive: -10% cooldowns",
]

var _upgrades: int = 0
var _gems: int = 0
var _title: Label
var _rows: VBoxContainer

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

func refresh(upgrades: int, gems: int) -> void:
	_upgrades = upgrades
	_gems = gems
	if visible:
		_rebuild()

func toggle() -> void:
	visible = not visible
	if visible:
		_rebuild()

func close() -> void:
	visible = false

func _rebuild() -> void:
	_title.text = "MERCHANT  —  %d gems" % _gems
	for c in _rows.get_children():
		c.queue_free()
	for item_id in UpgradeDefs.ITEM_COUNT:
		_rows.add_child(_make_row(item_id))

func _make_row(item_id: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(60, 0)
	name_label.text = ITEM_NAMES[item_id]
	row.add_child(name_label)
	var blurb := Label.new()
	blurb.custom_minimum_size = Vector2(190, 0)
	blurb.text = ITEM_BLURBS[item_id]
	blurb.add_theme_color_override("font_color", Color(0.68, 0.7, 0.76))
	row.add_child(blurb)
	var status := Label.new()
	status.custom_minimum_size = Vector2(56, 0)
	row.add_child(status)
	if item_id <= UpgradeDefs.ITEM_UP_SLAM:
		status.text = "Lv %d/%d" % [UpgradeDefs.skill_level(_upgrades, item_id), UpgradeDefs.MAX_SKILL_LEVEL]
	elif not UpgradeDefs.item_available(item_id, _upgrades):
		status.text = "Owned"
	if UpgradeDefs.item_available(item_id, _upgrades):
		var cost := UpgradeDefs.item_cost(item_id, _upgrades)
		var btn := Button.new()
		btn.text = "Buy  %d" % cost
		btn.disabled = _gems < cost
		var iid := item_id  # capture a copy, not the loop variable
		btn.pressed.connect(func(): purchase_pressed.emit(iid))
		row.add_child(btn)
	return row
