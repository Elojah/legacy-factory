class_name BiomeRegistry
## Maps a biome id to its tiles in the baked terrain atlas
## (assets/tiles/terrain.png — see tools/art_baker.gd). The atlas is a 3-col x 6-row
## grid: columns = floor / floor_alt / cliff (column 2 is the rocky cliff/rim tile
## FloorRenderer tiles under the floating islands — NOT a top-down wall), rows =
## forest / desert / snow / swamp / volcano / savanna. A biome is simply a row, so the
## procedural generator can pick a different biome per island without touching the
## renderer.

const TILE_SIZE := 16

# Biome ids == atlas rows (keep in sync with the row order in tools/art_baker.gd).
const FOREST := 0
const DESERT := 1
const SNOW := 2
const SWAMP := 3
const VOLCANO := 4
const SAVANNA := 5

# Number of biomes (== atlas rows). The procedural generator assigns a distinct
# biome per island while island_count <= BIOME_COUNT. Bump this (and bake matching
# atlas rows in tools/art_baker.gd) to add more.
const BIOME_COUNT := 6

# Atlas columns.
const COL_FLOOR := 0
const COL_FLOOR_ALT := 1
const COL_WALL := 2   # column 2 = the rocky cliff/rim tile (island undersides), not a wall

static func floor_coord(biome: int) -> Vector2i:
	return Vector2i(COL_FLOOR, biome)

static func floor_alt_coord(biome: int) -> Vector2i:
	return Vector2i(COL_FLOOR_ALT, biome)

static func wall_coord(biome: int) -> Vector2i:
	return Vector2i(COL_WALL, biome)
