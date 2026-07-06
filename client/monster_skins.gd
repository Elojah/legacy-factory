class_name MonsterSkins
## Client-only cosmetic species pick for KIND_MONSTER: the species is derived
## from the biome of the island CONTAINING the monster's position at first sight.
## Monsters spawn on an island, leash back to their home and respawn AT it
## (CLAUDE.md), so every client resolves the same island — and therefore the
## same species — no matter when it joins. Purely visual; never feeds the sim.
##
## NOT in any tools compile graph (references Session at runtime) — keep it out
## of tools/ preloads.

const SPECIES_SLIME := 0
const SPECIES_BEETLE := 1
const SPECIES_WISP := 2

static func species_for(state: EntityState) -> int:
	var geo: WorldGeometry = Session.geometry
	if geo == null:
		return SPECIES_SLIME
	for i in geo.islands.size():
		if geo.islands[i].has_point(state.pos):
			return species_for_biome(geo.island_biomes[i])
	return SPECIES_SLIME  # mid-bridge stragglers default to the classic slime

static func species_for_biome(biome: int) -> int:
	match biome:
		BiomeRegistry.DESERT, BiomeRegistry.SAVANNA:
			return SPECIES_BEETLE
		BiomeRegistry.SNOW, BiomeRegistry.VOLCANO:
			return SPECIES_WISP
		_:
			return SPECIES_SLIME  # FOREST, SWAMP
