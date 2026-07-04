class_name Hotbar extends Control
## 7-slot skill hotbar (keys 1-7), fully procedural _draw in the placeholder
## style — no theme, no textures. Fed the predicted EntityState every frame by
## ClientWorld -> HUD (same direct-polling pattern as the HP label), so cooldown
## fills and the active-cast highlight reflect prediction and roll back with it.
## Slot i maps to AbilityDefs.PLAYER_ABILITIES[i] — ids are NOT contiguous past
## slot 4 (NOVA/VOLLEY are 10/11); locked unlockables draw dimmed with a padlock.

const SLOT: float = 24.0
const GAP: float = 4.0
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
	for i in AbilityDefs.PLAYER_ABILITY_COUNT:
		var aid: int = AbilityDefs.PLAYER_ABILITIES[i]
		var rect := Rect2(Vector2(float(i) * (SLOT + GAP), 0.0), Vector2(SLOT, SLOT))
		# Slot panel.
		draw_rect(rect, Color(0.08, 0.09, 0.12, 0.85))
		if not UpgradeDefs.has_skill(_upgrades, aid):
			# Locked (merchant-unlockable): ghosted icon + padlock, no cd overlay.
			_draw_icon(aid, rect.position + Vector2(SLOT, SLOT) * 0.5, 0.15)
			_draw_padlock(rect.position + Vector2(SLOT, SLOT) * 0.5)
			draw_rect(rect, Color(0.25, 0.27, 0.32), false, 1.0)
			draw_string(font, rect.position + Vector2(2.0, 8.0), ICON_KEYS[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 8, Color(0.5, 0.5, 0.55))
			continue
		var is_active := casting and _casting_id == aid
		# Icon (greyed while another cast is committing).
		var dim := 0.45 if (casting and not is_active) else 1.0
		_draw_icon(aid, rect.position + Vector2(SLOT, SLOT) * 0.5, dim)
		# Cooldown overlay: darken from the top, draining as the cd expires.
		# Upgrade-aware denominator (dash levels + FOCUS shrink the base).
		var cd_max := UpgradeDefs.cooldown_for(aid, _upgrades)
		if _cds[i] > 0 and cd_max > 0:
			var frac := clampf(float(_cds[i]) / float(cd_max), 0.0, 1.0)
			draw_rect(Rect2(rect.position, Vector2(SLOT, SLOT * frac)), Color(0.0, 0.0, 0.0, 0.65))
		# Border: bright while this slot is casting.
		var border := Color(1.0, 0.9, 0.4) if is_active else Color(0.35, 0.38, 0.45)
		draw_rect(rect, border, false, 1.0)
		# Keybind label.
		draw_string(font, rect.position + Vector2(2.0, 8.0), ICON_KEYS[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 8, Color(0.9, 0.9, 0.95))

## Tiny procedural glyph per ability, centered on `c`.
func _draw_icon(ability_id: int, c: Vector2, dim: float) -> void:
	match ability_id:
		AbilityDefs.MELEE:
			# Sword swing arc.
			draw_arc(c + Vector2(0, 2), 7.0, -PI * 0.8, -PI * 0.2, 12, Color(0.95, 0.95, 1.0, dim), 2.0)
			draw_line(c + Vector2(-3, 5), c + Vector2(4, -4), Color(0.8, 0.85, 0.95, dim), 1.5)
		AbilityDefs.BOLT:
			# Bolt with a trail.
			draw_line(c + Vector2(-7, 3), c + Vector2(1, -1), Color(1.0, 0.85, 0.4, 0.6 * dim), 2.0)
			draw_circle(c + Vector2(3, -2), 3.0, Color(1.0, 0.95, 0.6, dim))
		AbilityDefs.DASH:
			# Speed chevrons.
			for k in 3:
				var x := -6.0 + 5.0 * float(k)
				var col := Color(0.7, 0.9, 1.0, dim * (0.5 + 0.25 * float(k)))
				draw_line(c + Vector2(x, -5), c + Vector2(x + 4, 0), col, 1.5)
				draw_line(c + Vector2(x, 5), c + Vector2(x + 4, 0), col, 1.5)
		AbilityDefs.HEAL:
			# Plus sign.
			draw_rect(Rect2(c + Vector2(-2, -7), Vector2(4, 14)), Color(0.4, 1.0, 0.5, dim))
			draw_rect(Rect2(c + Vector2(-7, -2), Vector2(14, 4)), Color(0.4, 1.0, 0.5, dim))
		AbilityDefs.SLAM:
			# Shockwave rings.
			draw_arc(c, 7.5, 0.0, TAU, 20, Color(1.0, 0.6, 0.3, dim), 2.0)
			draw_circle(c, 2.5, Color(1.0, 0.8, 0.4, dim))
		AbilityDefs.NOVA:
			# Radial burst: bright core + 8 spokes.
			draw_circle(c, 2.5, Color(0.75, 0.9, 1.0, dim))
			for k in 8:
				var d := Vector2.RIGHT.rotated(TAU * float(k) / 8.0)
				draw_line(c + d * 4.0, c + d * 8.0, Color(0.55, 0.75, 1.0, dim), 1.5)
		AbilityDefs.VOLLEY:
			# Three diverging bolts fanning up from the bottom edge.
			for k in 3:
				var d := Vector2.UP.rotated(deg_to_rad(-22.0 + 22.0 * float(k)))
				var base := c + Vector2(0, 7)
				draw_line(base, base + d * 13.0, Color(1.0, 0.85, 0.5, dim), 1.5)
				draw_circle(base + d * 13.0, 1.2, Color(1.0, 0.95, 0.7, dim))

## Padlock over a locked unlockable slot.
func _draw_padlock(c: Vector2) -> void:
	var col := Color(0.8, 0.76, 0.55)
	draw_rect(Rect2(c + Vector2(-4, -1), Vector2(8, 7)), col)
	draw_arc(c + Vector2(0, -1), 3.0, PI, TAU, 10, col, 1.5)
