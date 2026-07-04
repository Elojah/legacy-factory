class_name GameSettings
## Client-only persisted settings (master volume + fullscreen), stored in
## user://settings.cfg. All-static: loaded/applied once by Bootstrap on the
## client branch, edited live by SettingsPanel. The dedicated server never
## touches this (and apply_fullscreen no-ops on a headless display anyway).

const SETTINGS_CFG := "user://settings.cfg"
## linear_to_db(0) is -inf; below this floor we hard-mute at -80 dB instead.
const MIN_AUDIBLE := 0.001
const MUTE_DB := -80.0

static var master_volume: float = 1.0  # linear 0..1
static var fullscreen: bool = false

static func load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_CFG) != OK:
		master_volume = 1.0  # missing/corrupt file -> defaults
		fullscreen = false
		return
	master_volume = clampf(float(cfg.get_value("audio", "master_volume", 1.0)), 0.0, 1.0)
	fullscreen = bool(cfg.get_value("display", "fullscreen", false))

static func save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("display", "fullscreen", fullscreen)
	if cfg.save(SETTINGS_CFG) != OK:
		push_warning("[GameSettings] failed to save %s" % SETTINGS_CFG)

static func apply() -> void:
	apply_volume()
	apply_fullscreen()

static func apply_volume() -> void:
	# Bus 0 ("Master") always exists — no bus layout resource needed.
	var db: float = linear_to_db(master_volume) if master_volume > MIN_AUDIBLE else MUTE_DB
	AudioServer.set_bus_volume_db(0, db)

static func apply_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return  # headless client bots must never touch the window
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
