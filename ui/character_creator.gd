extends Control
## Character creator: pick class (visual only), hair style, hair color, skin
## tone and faction with a live animated preview. Every change re-bakes the
## preview sheet via CharSpriteFrames/CharPainter in a normal UI frame (which
## doubles as a natural native-type prewarm on first run, before any networking
## exists). Save writes the choice to Session + user://character.cfg; Back
## discards. Display names are UI-only strings — the index specs live in
## shared/net/appearance.gd and shared/sim/faction_defs.gd (faction names/colors
## in client/faction_palette.gd).

const HAIR_STYLE_NAMES := ["Short", "Long", "Spiky", "Bald"]
const HAIR_COLOR_NAMES := ["Brown", "Black", "Blonde", "Red", "White", "Blue"]
const SKIN_TONE_NAMES := ["Default", "Tan", "Dark", "Pale"]
# The preview cycles through all three sheet rows (side is shown both ways).
const FACING_ANIMS := ["walk_down", "walk_side", "walk_up", "walk_side"]

@onready var _preview: AnimatedSprite2D = $CenterContainer/HBox/PreviewBox/PreviewFrame/PreviewAnchor/Preview
@onready var _class_buttons: Array[Button] = [
	$CenterContainer/HBox/Options/ClassRow/Warrior as Button,
	$CenterContainer/HBox/Options/ClassRow/Mage as Button,
	$CenterContainer/HBox/Options/ClassRow/Archer as Button,
]
@onready var _hair_style_value: Label = $CenterContainer/HBox/Options/HairStyleRow/Value
@onready var _hair_color_value: Label = $CenterContainer/HBox/Options/HairColorRow/Value
@onready var _skin_tone_value: Label = $CenterContainer/HBox/Options/SkinToneRow/Value
@onready var _faction_value: Label = $CenterContainer/HBox/Options/FactionRow/Value

var _char_class: int = 0
var _hair_style: int = 0
var _hair_color: int = 0
var _skin_tone: int = 0
var _faction_idx: int = 0  # 0-based; the wire faction id is _faction_idx + 1
var _face_idx: int = 0

func _ready() -> void:
	# Start from the saved look so re-editing is incremental.
	_char_class = Appearance.char_class_of(Session.appearance)
	_hair_style = Appearance.hair_style_of(Session.appearance)
	_hair_color = Appearance.hair_color_of(Session.appearance)
	_skin_tone = Appearance.skin_tone_of(Session.appearance)
	_faction_idx = clampi(Session.faction, FactionDefs.FACTION_FIRST, FactionDefs.FACTION_COUNT) - 1

	for i in _class_buttons.size():
		var cls := i
		_class_buttons[i].pressed.connect(func(): _set_class(cls))
	_class_buttons[_char_class].button_pressed = true

	_wire_cycle($CenterContainer/HBox/Options/HairStyleRow, func(d: int): _hair_style = wrapi(_hair_style + d, 0, Appearance.HAIR_STYLE_COUNT))
	_wire_cycle($CenterContainer/HBox/Options/HairColorRow, func(d: int): _hair_color = wrapi(_hair_color + d, 0, Appearance.HAIR_COLOR_COUNT))
	_wire_cycle($CenterContainer/HBox/Options/SkinToneRow, func(d: int): _skin_tone = wrapi(_skin_tone + d, 0, Appearance.SKIN_TONE_COUNT))
	_wire_cycle($CenterContainer/HBox/Options/FactionRow, func(d: int): _faction_idx = wrapi(_faction_idx + d, 0, FactionDefs.FACTION_COUNT))

	$CenterContainer/HBox/Options/ButtonRow/Save.pressed.connect(_on_save)
	$CenterContainer/HBox/Options/ButtonRow/Back.pressed.connect(_on_back)
	$FacingTimer.timeout.connect(_on_facing_tick)
	_refresh()

func _wire_cycle(row: Node, apply: Callable) -> void:
	row.get_node("Prev").pressed.connect(_on_cycle.bind(apply, -1))
	row.get_node("Next").pressed.connect(_on_cycle.bind(apply, 1))

func _on_cycle(apply: Callable, delta: int) -> void:
	apply.call(delta)
	_refresh()

func _set_class(cls: int) -> void:
	_char_class = cls
	_refresh()

func _encoded() -> int:
	return Appearance.encode(_char_class, _hair_style, _hair_color, _skin_tone)

func _refresh() -> void:
	_hair_style_value.text = HAIR_STYLE_NAMES[_hair_style]
	_hair_color_value.text = HAIR_COLOR_NAMES[_hair_color]
	_skin_tone_value.text = SKIN_TONE_NAMES[_skin_tone]
	_faction_value.text = FactionPalette.name_of(_faction_idx + 1)
	_faction_value.add_theme_color_override("font_color", FactionPalette.color_for(_faction_idx + 1))
	_preview.sprite_frames = CharSpriteFrames.get_for(NetConfig.KIND_PLAYER, _encoded())
	_preview.play(FACING_ANIMS[_face_idx])

func _on_facing_tick() -> void:
	_face_idx = (_face_idx + 1) % FACING_ANIMS.size()
	_preview.flip_h = (_face_idx == 3)  # second side pass mirrors, like in-game LEFT
	_preview.play(FACING_ANIMS[_face_idx])

func _on_save() -> void:
	Session.appearance = _encoded()
	Session.faction = _faction_idx + 1
	Session.save_character()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
