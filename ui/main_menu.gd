extends Control
## Main menu: Play / Character / Settings / Exit. Play opens the lobby browser
## (which connects to the dedicated server); Character opens the creator. Settings
## opens the shared SettingsPanel (also used by the in-game pause menu). The menu
## does no networking itself, so it loads instantly with no server running.

@onready var _settings_btn: Button = $CenterContainer/VBox/Settings

var _settings_layer: CenterContainer = null  # built lazily on first open

func _ready() -> void:
	theme = UiTheme.get_theme()
	# Prewarm the native RNG type and reset any prior session (returning from a
	# game). clear() keeps Session.appearance — the character survives lobbies.
	Session.warm()
	Session.clear()
	$CenterContainer/VBox/Play.pressed.connect(_on_play)
	$CenterContainer/VBox/Character.pressed.connect(_on_character)
	_settings_btn.pressed.connect(_on_settings)
	$CenterContainer/VBox/Exit.pressed.connect(_on_exit)

func _on_play() -> void:
	get_tree().change_scene_to_file("res://scenes/lobby_browser.tscn")

func _on_character() -> void:
	get_tree().change_scene_to_file("res://scenes/character_creator.tscn")

func _on_settings() -> void:
	if _settings_layer == null:
		_settings_layer = CenterContainer.new()
		_settings_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		var panel := SettingsPanel.new()
		panel.back_pressed.connect(_on_settings_back)
		_settings_layer.add_child(panel)
		add_child(_settings_layer)
	_settings_layer.visible = true
	$CenterContainer.visible = false

func _on_settings_back() -> void:
	_settings_layer.visible = false
	$CenterContainer.visible = true

func _on_exit() -> void:
	get_tree().quit()
