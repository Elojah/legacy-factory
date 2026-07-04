class_name FactionDefs
## Faction indices + the 2-bit-packed pair-relations table (u16 on the wire).
## The ONLY place that decides faction hostility/alliance — deterministic shared
## code, consumed by WorldSim/HitboxResolver on both ends. Static consts only
## (no autoload calls) so --script tools can depend on it. Names/colors are
## client cosmetics and live in client/faction_palette.gd, never here.

const FACTION_NONE: int = 0    # monsters/bosses/their transients — always hostile
const FACTION_FIRST: int = 1
const FACTION_COUNT: int = 4   # canonical player factions are 1..4
const MIN_LOBBY_FACTIONS: int = 2
const MAX_LOBBY_FACTIONS: int = 4

# 2-bit relation values per faction pair; 3 is invalid -> sanitized to NEUTRAL.
const REL_NEUTRAL: int = 0
const REL_ALLIED: int = 1
const REL_RIVAL: int = 2
const PAIR_COUNT: int = 6      # C(4,2) pairs -> 12 bits used of the u16
const RELATIONS_ALL_NEUTRAL: int = 0

# Diplomacy wire constants (client_diplomacy_action / diplomacy_event payloads).
# "Accept" is not a wire action: proposing back forms the alliance.
const DIPLO_DECLARE_RIVALRY: int = 0
const DIPLO_PROPOSE_ALLIANCE: int = 1
const DIPLO_BREAK_ALLIANCE: int = 2
const EVENT_RIVALRY_DECLARED: int = 0
const EVENT_ALLIANCE_PROPOSED: int = 1
const EVENT_ALLIANCE_FORMED: int = 2
const EVENT_ALLIANCE_BROKEN: int = 3

## Upper-triangular pair index for factions 1..4, order-insensitive:
## (1,2)=0 (1,3)=1 (1,4)=2 (2,3)=3 (2,4)=4 (3,4)=5
static func pair_index(fa: int, fb: int) -> int:
	var a := mini(fa, fb) - 1
	var b := maxi(fa, fb) - 1
	return a * FACTION_COUNT - (a * (a + 1)) / 2 + (b - a - 1)

static func relation_of(fa: int, fb: int, relations: int) -> int:
	return (relations >> (pair_index(fa, fb) * 2)) & 0x3

static func set_relation(relations: int, fa: int, fb: int, rel: int) -> int:
	var shift := pair_index(fa, fb) * 2
	return (relations & ~(0x3 << shift)) | ((rel & 0x3) << shift)

## THE hostility predicate. Anything involving a non-faction participant
## (monsters, bosses, their projectiles/zones) stays hostile — PvE unchanged.
## Player-vs-player: same faction and allies are protected; only RIVAL fights.
static func are_hostile(fa: int, fb: int, relations: int) -> bool:
	if fa <= FACTION_NONE or fb <= FACTION_NONE:
		return true
	if fa == fb:
		return false
	return relation_of(fa, fb, relations) == REL_RIVAL

## Friendly = heal-splash-eligible: same faction or ALLIED (players only).
static func are_allied(fa: int, fb: int, relations: int) -> bool:
	if fa <= FACTION_NONE or fb <= FACTION_NONE:
		return false
	return fa == fb or relation_of(fa, fb, relations) == REL_ALLIED

## Clamp a faction into 1..count; 0/out-of-range -> 0 ("let the server assign").
static func sanitize_faction(f: int, count: int) -> int:
	return f if f >= FACTION_FIRST and f <= count else FACTION_NONE

## Zero the unused high bits and map the invalid 2-bit value 3 to NEUTRAL.
static func sanitize_relations(relations: int) -> int:
	var out := 0
	for pi in PAIR_COUNT:
		var rel := (relations >> (pi * 2)) & 0x3
		if rel > REL_RIVAL:
			rel = REL_NEUTRAL
		out |= rel << (pi * 2)
	return out
