class_name DiplomacyPanel extends PanelContainer
## Faction diplomacy panel (toggled with P). One row per active faction: color
## swatch + name + the relation vs OUR faction + the legal action buttons per
## the diplomacy rules (escalation unilateral, alliances by mutual proposal —
## "Accept" just proposes back). Pure UI: state is fed by ClientWorld through
## HUD.refresh_diplomacy and button presses surface via action_pressed; the
## server (Lobby.apply_diplomacy) revalidates everything anyway.

signal action_pressed(target_faction: int, action: int)

var _my_faction: int = FactionDefs.FACTION_NONE
var _faction_count: int = FactionDefs.MIN_LOBBY_FACTIONS
var _relations: int = FactionDefs.RELATIONS_ALL_NEUTRAL
var _pending: Dictionary = {}  # pair_index -> proposing faction

var _rows: VBoxContainer

func _ready() -> void:
	visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var title := Label.new()
	title.text = "DIPLOMACY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	box.add_child(_rows)

func refresh(my_faction: int, faction_count: int, relations: int, pending: Dictionary) -> void:
	_my_faction = my_faction
	_faction_count = faction_count
	_relations = relations
	_pending = pending
	if visible:
		_rebuild()

func toggle() -> void:
	visible = not visible
	if visible:
		_rebuild()

func close() -> void:
	visible = false

func _rebuild() -> void:
	for c in _rows.get_children():
		c.queue_free()
	for f in range(FactionDefs.FACTION_FIRST, _faction_count + 1):
		_rows.add_child(_make_row(f))

func _make_row(f: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(14, 14)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	swatch.color = FactionPalette.color_for(f)
	row.add_child(swatch)
	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(120, 0)
	name_label.text = FactionPalette.name_of(f)
	name_label.add_theme_color_override("font_color", FactionPalette.color_for(f))
	row.add_child(name_label)
	var rel_label := Label.new()
	rel_label.custom_minimum_size = Vector2(70, 0)
	row.add_child(rel_label)
	if f == _my_faction:
		rel_label.text = "YOU"
		return row
	if _my_faction == FactionDefs.FACTION_NONE:
		rel_label.text = "-"  # not spawned yet: read-only
		return row
	var rel := FactionDefs.relation_of(_my_faction, f, _relations)
	var pi := FactionDefs.pair_index(_my_faction, f)
	match rel:
		FactionDefs.REL_ALLIED:
			rel_label.text = "Allied"
			row.add_child(_make_action("Break Alliance", f, FactionDefs.DIPLO_BREAK_ALLIANCE))
			row.add_child(_make_action("Declare Rivalry", f, FactionDefs.DIPLO_DECLARE_RIVALRY))
		FactionDefs.REL_RIVAL:
			rel_label.text = "RIVAL"
			row.add_child(_make_propose(f, pi))
		_:
			rel_label.text = "Neutral"
			row.add_child(_make_propose(f, pi))
			row.add_child(_make_action("Declare Rivalry", f, FactionDefs.DIPLO_DECLARE_RIVALRY))
	return row

## The propose button relabels to "Accept Alliance" when the other side already
## proposed, and disables once OUR proposal is pending (duplicate = no-op).
func _make_propose(f: int, pi: int) -> Button:
	var proposer: int = _pending.get(pi, FactionDefs.FACTION_NONE)
	var btn := _make_action("Accept Alliance" if proposer == f else "Propose Alliance",
		f, FactionDefs.DIPLO_PROPOSE_ALLIANCE)
	if proposer == _my_faction:
		btn.text = "Proposed..."
		btn.disabled = true
	return btn

func _make_action(label: String, f: int, action: int) -> Button:
	var btn := Button.new()
	btn.text = label
	var target := f  # capture a copy, not the caller's loop variable
	var act := action
	btn.pressed.connect(func(): action_pressed.emit(target, act))
	return btn
