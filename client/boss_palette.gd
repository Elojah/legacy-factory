class_name BossPalette
## Client-only kit colors, keyed by BossDefs.KIT_* (which rides the visual-only
## EntityState.appearance field on bosses and hazards). Cosmetic — never sim.

static func color_for(kit: int) -> Color:
	match kit:
		BossDefs.KIT_MAGMA:
			return Color(1.0, 0.5, 0.25)
		BossDefs.KIT_FROST:
			return Color(0.55, 0.8, 1.0)
		_:
			return Color(0.55, 0.9, 0.4)  # KIT_SWAMP
