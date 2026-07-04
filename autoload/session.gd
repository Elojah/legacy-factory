extends Node
## Session — client-only holder for the lobby the player has joined, carried across
## the menu -> browser -> game scene swaps (autoloads persist). The game scene
## (client_world) builds its WorldGeometry from `seed`+`size` here. Unused on the
## server, which keeps per-lobby state in the Lobby objects instead.

var lobby_id: int = -1
var seed: int = 0
var size: int = WorldGenerator.SIZE_MEDIUM
var faction_count: int = FactionDefs.MIN_LOBBY_FACTIONS  # this lobby's active factions
var geometry: WorldGeometry = null

# Cross-lobby identity: the player's chosen look (Appearance-encoded) + faction
# pick, loaded from disk by Bootstrap at startup and sent with ready_in_lobby.
# Deliberately NOT reset by clear() — leaving a game must not reset the
# character. The server validates the faction against the lobby's count and may
# auto-assign a different one (the authoritative value rides EntityState).
var appearance: int = Appearance.DEFAULT
var faction: int = FactionDefs.FACTION_FIRST

# Headless test hook (--cast <skill>): button bits OR'd into every captured
# input so a bot client can exercise one ability. 0 = disabled (normal play).
var auto_cast_buttons: int = 0
# Headless test hook (--auto-tp): the bot requests waypoint travel every ~2 s
# and prints every teleport_event, so the whole loop is verifiable headless.
var auto_tp: bool = false

const CHARACTER_CFG := "user://character.cfg"

## Prewarm the native RandomNumberGenerator type in a normal frame so the first
## WorldGenerator.generate() (which may run close to an RPC handler) doesn't trip
## the 4.7 native-.new()-in-RPC-frame bug. Call from the menu's _ready.
func warm() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 0

func set_lobby(p_lobby_id: int, p_seed: int, p_size: int, p_factions: int) -> void:
	lobby_id = p_lobby_id
	seed = p_seed
	size = p_size
	faction_count = p_factions
	geometry = null  # rebuilt by the game scene from seed+size

func clear() -> void:
	lobby_id = -1
	seed = 0
	size = WorldGenerator.SIZE_MEDIUM
	faction_count = FactionDefs.MIN_LOBBY_FACTIONS
	geometry = null

# --- character persistence -----------------------------------------------------
func has_saved_character() -> bool:
	return FileAccess.file_exists(CHARACTER_CFG)

func load_character() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CHARACTER_CFG) != OK:
		appearance = Appearance.DEFAULT  # missing/corrupt file -> default look
		faction = FactionDefs.FACTION_FIRST
		return
	appearance = Appearance.sanitize(Appearance.encode(
		int(cfg.get_value("character", "char_class", 0)),
		int(cfg.get_value("character", "hair_style", 0)),
		int(cfg.get_value("character", "hair_color", 0)),
		int(cfg.get_value("character", "skin_tone", 0))))
	# Sanitize against the canonical 4; per-lobby validity is the server's job.
	faction = clampi(int(cfg.get_value("character", "faction", FactionDefs.FACTION_FIRST)),
		FactionDefs.FACTION_FIRST, FactionDefs.FACTION_COUNT)

func save_character() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("character", "char_class", Appearance.char_class_of(appearance))
	cfg.set_value("character", "hair_style", Appearance.hair_style_of(appearance))
	cfg.set_value("character", "hair_color", Appearance.hair_color_of(appearance))
	cfg.set_value("character", "skin_tone", Appearance.skin_tone_of(appearance))
	cfg.set_value("character", "faction", faction)
	if cfg.save(CHARACTER_CFG) != OK:
		push_warning("[Session] failed to save %s" % CHARACTER_CFG)
