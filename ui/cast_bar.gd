class_name CastBar extends Control
## Teleport channel progress bar (bottom-center, above the hotbar). Driven by
## ClientWorld from the synced GameClock: begin() on the server's STARTED event,
## set_progress() every frame, end() on completion/cancel. Pure UI — the server
## owns the actual channel (Lobby._tick_teleports).

var _bar: ProgressBar
var _label: Label

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bar)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_label)

func begin() -> void:
	visible = true
	set_progress(0.0, float(TeleportDefs.TP_CAST_TICKS) / float(NetConfig.TICK_RATE))

func set_progress(frac: float, remaining_sec: float) -> void:
	_bar.value = clampf(frac, 0.0, 1.0)
	_label.text = "Teleporting…  %.1f s" % maxf(0.0, remaining_sec)

func end() -> void:
	visible = false
