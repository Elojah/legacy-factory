class_name UiTheme
## Runtime-built Theme: the baked pixel font + UiPalette styleboxes applied to
## every default Control (menus, browser, panels, buttons) in one shot — no
## .tres authoring, consistent with the everything-is-code-baked pipeline.
## Built lazily in a normal frame (menu/_ready paths only — never construct it
## inside a snapshot/RPC handler; the 4.7 native-.new() note in CLAUDE.md).
##
## The pixel font is a 9px bitmap: use size 9 or 18 (integer multiples only).

const FONT_SIZE := 18   # 2x the 9px bitmap — crisp integer scaling

static var _theme: Theme = null

static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	var font: FontFile = load("res://assets/fonts/pixel.fnt")
	# Integer up-scaling only: fractional sizes would blur the bitmap glyphs.
	font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
	var t: Theme = Theme.new()
	t.default_font = font
	t.default_font_size = FONT_SIZE

	var panel := _box(UiPalette.PANEL_BG, UiPalette.PANEL_BORDER, 2, 10)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)

	t.set_stylebox("normal", "Button", _box(UiPalette.BUTTON_BG, UiPalette.PANEL_BORDER, 2, 6))
	t.set_stylebox("hover", "Button", _box(UiPalette.BUTTON_BG_HOVER, UiPalette.ACCENT_GOLD, 2, 6))
	t.set_stylebox("pressed", "Button", _box(UiPalette.BUTTON_BG_PRESSED, UiPalette.ACCENT_GOLD, 2, 6))
	t.set_stylebox("disabled", "Button", _box(Color(0.10, 0.11, 0.14, 0.7), Color(0.24, 0.26, 0.31), 2, 6))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), UiPalette.ACCENT_GOLD, 1, 6))
	t.set_color("font_color", "Button", UiPalette.TEXT)
	t.set_color("font_hover_color", "Button", UiPalette.ACCENT_GOLD)
	t.set_color("font_pressed_color", "Button", UiPalette.ACCENT_GOLD)
	t.set_color("font_disabled_color", "Button", UiPalette.TEXT_DIM)

	t.set_color("font_color", "Label", UiPalette.TEXT)

	t.set_stylebox("normal", "LineEdit", _box(Color(0.06, 0.07, 0.10, 0.95), UiPalette.PANEL_BORDER, 2, 5))
	t.set_stylebox("focus", "LineEdit", _box(Color(0.06, 0.07, 0.10, 0.95), UiPalette.ACCENT_GOLD, 2, 5))
	t.set_color("font_color", "LineEdit", UiPalette.TEXT)
	t.set_color("caret_color", "LineEdit", UiPalette.ACCENT_GOLD)

	t.set_stylebox("background", "ProgressBar", _box(Color(0.05, 0.05, 0.08, 0.9), UiPalette.PANEL_BORDER, 1, 2))
	t.set_stylebox("fill", "ProgressBar", _box(UiPalette.ACCENT_GOLD, Color(0, 0, 0, 0), 0, 2))

	t.set_stylebox("panel", "ItemList", _box(Color(0.06, 0.07, 0.10, 0.95), UiPalette.PANEL_BORDER, 2, 6))
	t.set_color("font_color", "ItemList", UiPalette.TEXT)
	t.set_stylebox("selected", "ItemList", _box(Color(0.22, 0.24, 0.30), UiPalette.ACCENT_GOLD, 1, 2))
	t.set_stylebox("selected_focus", "ItemList", _box(Color(0.22, 0.24, 0.30), UiPalette.ACCENT_GOLD, 1, 2))

	_theme = t
	return _theme

## Apply the theme to a Control and every Control child (for CanvasLayer hosts
## like the HUD, whose children can't inherit from a non-Control parent).
static func apply(root: Node) -> void:
	if root is Control:
		(root as Control).theme = get_theme()
		return
	for c in root.get_children():
		if c is Control:
			(c as Control).theme = get_theme()

static func _box(bg: Color, border: Color, border_w: int, margin: int) -> StyleBoxFlat:
	var b: StyleBoxFlat = StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(border_w)
	b.set_content_margin_all(float(margin))
	b.corner_radius_top_left = 0
	b.corner_radius_top_right = 0
	b.corner_radius_bottom_left = 0
	b.corner_radius_bottom_right = 0
	return b
