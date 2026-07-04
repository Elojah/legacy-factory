class_name PauseMenu extends Control
## In-game ESC menu overlay. The sim never pauses (authoritative server) — this
## only dims the screen and, via HUD/ClientWorld, makes the local player send
## neutral inputs while open. Pure UI: Resume/Settings are handled here; Leave
## Lobby and Quit Game only emit — HUD performs the actions.

signal leave_pressed
signal quit_pressed

var _root_panel: PanelContainer
var _settings: SettingsPanel

func _ready() -> void:
	visible = false
	mouse_filter = MOUSE_FILTER_STOP  # modal: swallow clicks aimed at the world
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)
	_root_panel = _make_root_panel()
	center.add_child(_root_panel)
	_settings = SettingsPanel.new()
	_settings.visible = false
	_settings.back_pressed.connect(_show_root)
	center.add_child(_settings)

func _make_root_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	box.add_child(_make_button("Resume", close))
	box.add_child(_make_button("Settings", _show_settings))
	box.add_child(_make_button("Leave Lobby", func(): leave_pressed.emit()))
	box.add_child(_make_button("Quit Game", func(): quit_pressed.emit()))
	return panel

func _make_button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(220, 44)
	btn.text = text
	btn.pressed.connect(on_pressed)
	return btn

func open() -> void:
	_show_root()
	visible = true

func close() -> void:
	visible = false
	_show_root()  # reopen always lands on the root view

func toggle() -> void:
	if visible:
		close()
	else:
		open()

## ESC while open: settings view backs out to the root view, root view closes.
func escape() -> void:
	if _settings.visible:
		GameSettings.save_cfg()
		_show_root()
	else:
		close()

func _show_settings() -> void:
	_root_panel.visible = false
	_settings.visible = true

func _show_root() -> void:
	_settings.visible = false
	_root_panel.visible = true
