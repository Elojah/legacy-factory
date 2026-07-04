class_name BossDefs
## Boss kit + policy data. The three kits SHARE the AbilityDefs boss pool (ids
## are wire bytes); a kit only changes which pattern the server AI plays and how
## the client tints/draws — the shared sim never reads kit. Kit rides in
## EntityState.appearance (visual-only field) for bosses and hazards.

const KIT_MAGMA: int = 0    # Magma Titan — area denial (hazards + smashes)
const KIT_FROST: int = 1    # Frost Wyrm — skirmisher (charges + barrages)
const KIT_SWAMP: int = 2    # Swamp Horror — summoner attrition (minion waves)
const KIT_COUNT: int = 3

## 6 biomes -> 3 kits (2 each), so every seed maps to a kit.
static func kit_for_biome(biome: int) -> int:
	match biome:
		BiomeRegistry.VOLCANO, BiomeRegistry.DESERT:
			return KIT_MAGMA
		BiomeRegistry.SNOW, BiomeRegistry.FOREST:
			return KIT_FROST
		_:
			return KIT_SWAMP  # SWAMP, SAVANNA

static func kit_name(kit: int) -> String:
	match kit:
		KIT_MAGMA:
			return "Magma Titan"
		KIT_FROST:
			return "Frost Wyrm"
		_:
			return "Swamp Horror"

# --- server lifecycle policy (ticks @ 30 Hz; server-only, no wire impact) ------
const BOSS_RESPAWN_TICKS: int = 9000   # ~5 min after a raid kill
const MINION_REAP_TICKS: int = 90      # summoned-minion corpse linger; NEVER respawns

# --- AI policy ------------------------------------------------------------------
const PHASE_COUNT: int = 3
const PHASE_THRESHOLDS: Array[float] = [0.66, 0.33]  # hp fraction -> phase 0/1/2
# Tuned for the small-island layout: arena half-width is 352-512 px and the sky
# gap between islands is >= 768 px, so aggro can never span to a neighbour island
# and a player on an approach bridge cannot pull the boss off its arena.
const AGGRO_RADIUS: float = 340.0
const LEASH_RADIUS: float = 460.0      # beyond this from home: walk back + reset
const SMASH_WANT_RANGE: float = 70.0   # AI closes to this before smashing
const CHARGE_MIN_RANGE: float = 120.0  # AI never charges point-blank

static func phase_for_hp(hp: int, max_hp: int) -> int:
	var frac: float = float(hp) / float(maxi(1, max_hp))
	if frac <= PHASE_THRESHOLDS[1]:
		return 2
	if frac <= PHASE_THRESHOLDS[0]:
		return 1
	return 0

static func ability_for_button(btn: int) -> int:
	if btn == NetConfig.BTN_BOSS_SMASH:
		return AbilityDefs.BOSS_SMASH
	if btn == NetConfig.BTN_BOSS_BARRAGE:
		return AbilityDefs.BOSS_BARRAGE
	if btn == NetConfig.BTN_BOSS_SUMMON:
		return AbilityDefs.BOSS_SUMMON
	if btn == NetConfig.BTN_BOSS_HAZARD:
		return AbilityDefs.BOSS_HAZARD
	if btn == NetConfig.BTN_BOSS_CHARGE:
		return AbilityDefs.BOSS_CHARGE
	return -1

## The move cycle for (kit, phase): BTN_BOSS_* bits in cast order. Move 0 of each
## phase is the scripted phase-opener (the AI resets its step on a phase change).
## Built at call time — const expressions cannot reference the NetConfig autoload.
static func pattern(kit: int, phase: int) -> Array[int]:
	var smash: int = NetConfig.BTN_BOSS_SMASH
	var barrage: int = NetConfig.BTN_BOSS_BARRAGE
	var summon: int = NetConfig.BTN_BOSS_SUMMON
	var hazard: int = NetConfig.BTN_BOSS_HAZARD
	var charge: int = NetConfig.BTN_BOSS_CHARGE
	var table: Array = []
	match kit:
		KIT_FROST:   # mobile skirmisher: punish stacking, dodge the landings
			table = [
				[charge, smash, barrage],
				[charge, barrage, smash, hazard],
				[barrage, charge, hazard, smash],
			]
		KIT_SWAMP:   # summoner: bury the raid in adds + attrition zones
			table = [
				[summon, smash, hazard],
				[summon, hazard, smash, hazard],
				[summon, hazard, barrage, smash],
			]
		_:           # KIT_MAGMA: relentless area denial
			table = [
				[smash, hazard, smash, barrage],
				[hazard, smash, summon, barrage],
				[hazard, barrage, smash, hazard, summon],
			]
	var row: Array = table[clampi(phase, 0, table.size() - 1)]
	var out: Array[int] = []
	for b in row:
		out.append(int(b))
	return out
