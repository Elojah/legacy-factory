class_name FactionPalette
## Client-only faction names + colors, keyed by FactionDefs faction id (index 0
## is FACTION_NONE). Cosmetic — never sim; the sim-facing index spec and the
## hostility rules live in shared/sim/faction_defs.gd.

const NAMES := ["None", "Crimson Order", "Azure Pact", "Gilded Company", "Verdant Circle"]

static func name_of(faction: int) -> String:
	return NAMES[faction] if faction >= 0 and faction < NAMES.size() else NAMES[0]

static func color_for(faction: int) -> Color:
	match faction:
		1:
			return Color(0.9, 0.25, 0.25)   # Crimson Order
		2:
			return Color(0.3, 0.55, 1.0)    # Azure Pact
		3:
			return Color(0.95, 0.8, 0.25)   # Gilded Company
		4:
			return Color(0.35, 0.85, 0.4)   # Verdant Circle
		_:
			return Color.WHITE              # FACTION_NONE / unknown
