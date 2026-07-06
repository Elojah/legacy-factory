class_name Hotbar extends Control
## 7-slot skill hotbar (keys 1-7): baked pixel icons (assets/sprites/
## icons_skills.png, 24x24 cells indexed by ability id) in UiPalette-framed
## slots. Fed the predicted EntityState every frame by ClientWorld -> HUD (same
## direct-polling pattern as the HP label), so cooldown fills and the
## active-cast highlight reflect prediction and roll back with it.
## Slot i maps to AbilityDefs.PLAYER_ABILITIES[i] — ids are NOT contiguous past
## slot 4 (NOVA/VOLLEY are 10/11); locked unlockables draw dimmed with a padlock.

const ICONS := preload("res://assets/sprites/icons_skills.png")
const SLOT: float = 32.0
const GAP: float = 4.0
const ICON: float = 24.0
const ICON_KEYS: Array[String] = ["1", "2", "3", "4", "5", "6", "7"]

var _cds: PackedInt32Array = PackedInt32Array()
var _phase: int = Ability.PHASE_IDLE
var _casting_id: int = 0
var _upgrades: int = 0

func _ready() -> void:
	_cds.resize(AbilityDefs.PLAYER_ABILITY_COUNT)
	visible = false  # shown on the first state (after local player spawns)
	custom_minimum_size = Vector2(SLOT * AbilityDefs.PLAYER_ABILITY_COUNT + GAP * (AbilityDefs.PLAYER_ABILITY_COUNT - 1), SLOT)

func set_ability_state(s: EntityState) -> void:
	visible = true
	_phase = s.ability_phase
	_casting_id = s.ability_id
	_upgrades = s.upgrades
	for i in AbilityDefs.PLAYER_ABILITY_COUNT:
		_cds[i] = s.ability_cds[AbilityDefs.PLAYER_ABILITIES[i]]
	queue_redraw()

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var casting := _phase != Ability.PHASE_IDLE
	var pad := (SLOT - ICON) * 0.5
	for i in AbilityDefs.PLAYER_ABILITY_COUNT:
		var aid: int = AbilityDefs.PLAYER_ABILITIES[i]
		var rect := Rect2(Vector2(float(i) * (SLOT + GAP), 0.0), Vector2(SLOT, SLOT))
		var icon_src := Rect2(float(aid) * ICON, 0.0, ICON, ICON)
		var icon_dst := Rect2(rect.position + Vector2(pad, pad), Vector2(ICON, ICON))
		# Slot panel.
		draw_rect(rect, UiPalette.PANEL_BG)
		if not UpgradeDefs.has_skill(_upgrades, aid):
			# Locked (merchant-unlockable): ghosted icon + padlock, no cd overlay.
			draw_texture_rect_region(ICONS, icon_dst, icon_src, Color(1, 1, 1, 0.15))
			_draw_padlock(rect.position + Vector2(SLOT, SLOT) * 0.5)
			draw_rect(rect, Color(0.25, 0.27, 0.32), false, 1.0)
			draw_string(font, rect.position + Vector2(3.0, 11.0), ICON_KEYS[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, UiPalette.TEXT_DIM)
			continue
		var is_active := casting and _casting_id == aid
		# Icon (greyed while another cast is committing).
		var dim := 0.45 if (casting and not is_active) else 1.0
		draw_texture_rect_region(ICONS, icon_dst, icon_src, Color(1, 1, 1, dim))
		# Cooldown overlay: darken from the top, draining as the cd expires.
		# Upgrade-aware denominator (dash levels + FOCUS shrink the base).
		var cd_max := UpgradeDefs.cooldown_for(aid, _upgrades)
		if _cds[i] > 0 and cd_max > 0:
			var frac := clampf(float(_cds[i]) / float(cd_max), 0.0, 1.0)
			draw_rect(Rect2(rect.position, Vector2(SLOT, SLOT * frac)), Color(0.0, 0.0, 0.0, 0.65))
		# Border: gold while this slot is casting.
		var border := UiPalette.ACCENT_GOLD if is_active else UiPalette.PANEL_BORDER
		draw_rect(rect, border, false, 2.0 if is_active else 1.0)
		# Keybind label.
		draw_string(font, rect.position + Vector2(3.0, 11.0), ICON_KEYS[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, UiPalette.TEXT)

## Padlock over a locked unlockable slot.
func _draw_padlock(c: Vector2) -> void:
	var col := Color(0.8, 0.76, 0.55)
	draw_rect(Rect2(c + Vector2(-5, -1), Vector2(10, 8)), col)
	draw_arc(c + Vector2(0, -1), 4.0, PI, TAU, 10, col, 2.0)
