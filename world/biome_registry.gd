class_name BiomeRegistry
## Maps a biome id to its tiles in the baked terrain atlas
## (assets/tiles/terrain.png — see tools/art_baker.gd). The atlas is a 6-col x 6-row
## grid: columns = floor / floor_alt / floor_var2 / floor_var3 / cliff / edge-fringe
## (column 4 is the rocky cliff/rim tile FloorRenderer tiles under the floating
## islands — NOT a top-down wall; column 5 is the grass-overhang strip tiled along
## island bottom edges), rows = forest / desert / snow / swamp / volcano / savanna.
## A biome is simply a row, so the procedural generator can pick a different biome
## per island without touching the renderer.

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
const COL_FLOOR_VAR2 := 2   # lush variant (extra tufts/flowers)
const COL_FLOOR_VAR3 := 3   # bare variant (fissure + dry specks)
const COL_WALL := 4         # the rocky cliff/rim tile (island undersides), not a wall
const COL_EDGE := 5         # grass-overhang fringe strip (island bottom edges)

static func floor_coord(biome: int) -> Vector2i:
	return Vector2i(COL_FLOOR, biome)

static func floor_alt_coord(biome: int) -> Vector2i:
	return Vector2i(COL_FLOOR_ALT, biome)

static func floor_var_coord(biome: int, variant: int) -> Vector2i:
	return Vector2i(clampi(variant, 0, 3), biome)

static func wall_coord(biome: int) -> Vector2i:
	return Vector2i(COL_WALL, biome)

static func edge_coord(biome: int) -> Vector2i:
	return Vector2i(COL_EDGE, biome)
