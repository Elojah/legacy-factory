class_name SettingsPanel extends PanelContainer
## Reusable settings panel (master volume + fullscreen), shown inside the
## in-game pause menu and the main menu. Edits GameSettings live (changes
## apply immediately) and persists to user://settings.cfg. Pure UI: the host
## decides where it lives; Back only emits.

signal back_pressed

func _ready() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	box.add_child(_make_volume_row())
	box.add_child(_make_fullscreen_toggle())
	var back := Button.new()
	back.custom_minimum_size = Vector2(220, 44)
	back.text = "Back"
	back.pressed.connect(_on_back)
	box.add_child(back)

func _make_volume_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.custom_minimum_size = Vector2(120, 0)
	label.text = "Master Volume"
	label.add_theme_color_override("font_color", Color(0.68, 0.7, 0.76))
	row.add_child(label)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(180, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = GameSettings.master_volume
	slider.value_changed.connect(_on_volume_changed)
	slider.drag_ended.connect(func(_changed: bool): GameSettings.save_cfg())
	row.add_child(slider)
	return row

func _make_fullscreen_toggle() -> CheckButton:
	var check := CheckButton.new()
	check.text = "Fullscreen"
	check.button_pressed = GameSettings.fullscreen  # set BEFORE connecting toggled
	check.toggled.connect(_on_fullscreen_toggled)
	return check

func _on_volume_changed(value: float) -> void:
	GameSettings.master_volume = value
	GameSettings.apply_volume()

func _on_fullscreen_toggled(pressed: bool) -> void:
	GameSettings.fullscreen = pressed
	GameSettings.apply_fullscreen()
	GameSettings.save_cfg()

func _on_back() -> void:
	GameSettings.save_cfg()
	back_pressed.emit()
