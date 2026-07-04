class_name BossBar extends Control
## Top-center raid frame: boss name + a big hp bar, fully procedural in the
## placeholder style (no theme, no textures). ClientWorld feeds it the nearest
## boss every frame; hidden when no boss is near.

var _boss_name: String = ""
var _hp: int = 0
var _max_hp: int = 1

func _ready() -> void:
	visible = false

func show_boss(boss_name: String, hp: int, max_hp: int) -> void:
	if visible and boss_name == _boss_name and hp == _hp:
		return
	_boss_name = boss_name
	_hp = hp
	_max_hp = maxi(1, max_hp)
	visible = true
	queue_redraw()

func hide_boss() -> void:
	visible = false

func _draw() -> void:
	var w := size.x
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(0, 12), _boss_name, HORIZONTAL_ALIGNMENT_CENTER, w, 12, Color(1.0, 0.9, 0.8))
	var bar := Rect2(0, 16, w, 10)
	draw_rect(bar, Color(0.05, 0.05, 0.08, 0.8))
	var frac := clampf(float(maxi(0, _hp)) / float(_max_hp), 0.0, 1.0)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)), Color(0.85, 0.25, 0.2))
	draw_rect(bar, Color(0.6, 0.5, 0.4), false, 1.0)
	draw_string(font, Vector2(0, 24.5), "%d / %d" % [maxi(0, _hp), _max_hp],
		HORIZONTAL_ALIGNMENT_CENTER, w, 8, Color(1, 1, 1, 0.9))
