class_name BossBar extends Control
## Top-center raid frame: boss name + a big kit-colored hp bar with phase ticks
## at 66%/33% (BossDefs phase thresholds). ClientWorld feeds it the nearest boss
## every frame; hidden when no boss is near.

var _boss_name: String = ""
var _hp: int = 0
var _max_hp: int = 1
var _kit: int = 0

func _ready() -> void:
	visible = false

func show_boss(boss_name: String, hp: int, max_hp: int, kit: int = 0) -> void:
	if visible and boss_name == _boss_name and hp == _hp:
		return
	_boss_name = boss_name
	_hp = hp
	_max_hp = maxi(1, max_hp)
	_kit = kit
	visible = true
	queue_redraw()

func hide_boss() -> void:
	visible = false

func _draw() -> void:
	var w := size.x
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(0, 13), _boss_name, HORIZONTAL_ALIGNMENT_CENTER, w, 18, UiPalette.TEXT)
	var bar := Rect2(0, 16, w, 12)
	draw_rect(bar, UiPalette.PANEL_BG)
	var frac := clampf(float(maxi(0, _hp)) / float(_max_hp), 0.0, 1.0)
	var kit_col := BossPalette.color_for(_kit)
	draw_rect(Rect2(bar.position + Vector2(1, 1), Vector2((bar.size.x - 2.0) * frac, bar.size.y - 2.0)), kit_col.lerp(UiPalette.DANGER, 0.35))
	# Phase ticks: bosses shift patterns at 66% and 33% hp.
	for m in [0.6667, 0.3333]:
		var x: float = bar.position.x + bar.size.x * float(m)
		draw_line(Vector2(x, bar.position.y + 1.0), Vector2(x, bar.end.y - 1.0), Color(0, 0, 0, 0.55), 1.0)
	draw_rect(bar, UiPalette.PANEL_BORDER, false, 2.0)
	draw_string(font, Vector2(0, 25.5), "%d / %d" % [maxi(0, _hp), _max_hp],
		HORIZONTAL_ALIGNMENT_CENTER, w, 9, Color(1, 1, 1, 0.92))
