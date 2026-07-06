class_name Foliage extends Node2D
## Cosmetic foliage layer: trees + grass + rocks scattered across each island. Trees and
## grass sway in the wind (world/foliage_sway.gdshader) driven by a synced `wind_phase`
## from client_world (like the sky/water); rocks are static and drawn by this parent
## node (under the swaying children). Placement is derived CLIENT-SIDE from the lobby
## seed and NEVER touches the sim / WorldGeometry (players walk freely over it).
##
## Islands hold millions of tiles, so instances are SAMPLED directly (never enumerated)
## and hard-capped per kind + globally so the draw list stays small.

const SWAY_SHADER := preload("res://world/foliage_sway.gdshader")
const FOLIAGE_TEX := preload("res://assets/tiles/foliage.png")

# Atlas layout (assets/tiles/foliage.png = 12 cells of 16x24 in 2 rows; see
# tools/art_baker.gd). Cells are (col, row) atlas coords.
const CELL_W := 16
const CELL_H := 24
const TREE_CELLS: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
const GRASS_CELLS: Array[Vector2i] = [Vector2i(3, 0)]
const ROCK_CELLS: Array[Vector2i] = [Vector2i(4, 0), Vector2i(5, 0)]
# Ground decals (row 1), picked per biome so the set reads native to the ground.
const DECAL_FLOWER_A := Vector2i(0, 1)
const DECAL_FLOWER_B := Vector2i(1, 1)
const DECAL_PEBBLES := Vector2i(2, 1)
const DECAL_CRACK := Vector2i(3, 1)
const DECAL_STUMP := Vector2i(4, 1)
const DECAL_BUSH := Vector2i(5, 1)
const DECALS_FOREST: Array[Vector2i] = [DECAL_FLOWER_A, DECAL_FLOWER_B, DECAL_STUMP, DECAL_BUSH]
const DECALS_DESERT: Array[Vector2i] = [DECAL_PEBBLES, DECAL_CRACK, DECAL_PEBBLES]
const DECALS_SNOW: Array[Vector2i] = [DECAL_PEBBLES, DECAL_BUSH]
const DECALS_SWAMP: Array[Vector2i] = [DECAL_BUSH, DECAL_STUMP, DECAL_FLOWER_B]
const DECALS_VOLCANO: Array[Vector2i] = [DECAL_CRACK, DECAL_PEBBLES, DECAL_CRACK]
const DECALS_SAVANNA: Array[Vector2i] = [DECAL_BUSH, DECAL_FLOWER_B, DECAL_PEBBLES]

# Density (1 instance per this many world px^2) + per-island and global caps.
# Tuned for the SMALL islands (384-1024 px edges): a min island gets ~1 tree /
# ~5 grass, a max one ~8 trees / ~35 grass / ~4 rocks / ~15 decals.
const TREE_AREA_PER := 120000.0
const GRASS_AREA_PER := 30000.0
const ROCK_AREA_PER := 250000.0
const DECAL_AREA_PER := 45000.0
const TREE_CAP := 120
const GRASS_CAP := 500
const ROCK_CAP := 60
const DECAL_CAP := 400
const GLOBAL_CAP := 3500
const EDGE_MARGIN := 48.0     # keep foliage off the shoreline

# Subtle per-biome tint (multiplied onto the natural sprite colours via modulate).
const FOLIAGE_TINT: Array[Color] = [
	Color(1.00, 1.00, 1.00), Color(1.00, 0.90, 0.65), Color(0.85, 0.92, 1.00),
	Color(0.80, 0.90, 0.70), Color(0.90, 0.75, 0.70), Color(1.00, 0.95, 0.60),
]

var _geometry: WorldGeometry
var _grass_layer: FoliageLayer
var _tree_mat: ShaderMaterial
var _grass_mat: ShaderMaterial
var _tree_parent: Node2D = null           # y-sorted host (client_root Playfield)
var _tree_sprites: Array[Sprite2D] = []
var _tree_dest: Array[Rect2] = []
var _tree_src: Array[Rect2] = []
var _tree_mod: Array[Color] = []
var _rock_dest: Array[Rect2] = []
var _rock_src: Array[Rect2] = []
var _rock_mod: Array[Color] = []
var _decal_dest: Array[Rect2] = []
var _decal_src: Array[Rect2] = []
var _decal_mod: Array[Color] = []
var _total := 0

func _ready() -> void:
	# Build the sway materials in a normal frame (the 4.7 native-.new() note). Grass
	# sways more than trees; both share one shader with different amp. base_v = the
	# UV.y of each sprite's rooted base: tree sprites use a region (UV spans 0..1),
	# the grass batch samples row 0 of the 2-row atlas (base at UV.y = 0.5).
	_grass_mat = _make_mat(2.6, 0.020, 0.5)
	_tree_mat = _make_mat(2.0, 0.012, 1.0)
	_grass_layer = FoliageLayer.new()
	add_child(_grass_layer)
	if _geometry != null:
		_rebuild()

func setup(geometry: WorldGeometry) -> void:
	_geometry = geometry
	if is_node_ready():
		_rebuild()

## Host the tree sprites under a y-sorted parent shared with the entities (so
## actors walk in front of / behind trunks). Falls back to plain children of
## this layer when never called (art_preview).
func set_tree_parent(parent: Node2D) -> void:
	_tree_parent = parent
	if is_node_ready() and _geometry != null:
		_rebuild_trees()

## Push the synchronized wind phase to both sway materials (called each frame by
## client_world, mirroring sky.gd / water_renderer).
func set_wind_phase(p: float) -> void:
	if _grass_mat != null:
		_grass_mat.set_shader_parameter("wind_phase", p)
	if _tree_mat != null:
		_tree_mat.set_shader_parameter("wind_phase", p)

func _draw() -> void:
	# Ground decals first (flat on the floor), then rocks — both static (no
	# material), drawn by the parent so they sit under the swaying foliage.
	for i in _decal_dest.size():
		draw_texture_rect_region(FOLIAGE_TEX, _decal_dest[i], _decal_src[i], _decal_mod[i])
	for i in _rock_dest.size():
		draw_texture_rect_region(FOLIAGE_TEX, _rock_dest[i], _rock_src[i], _rock_mod[i])

func _rebuild() -> void:
	var grass_d: Array[Rect2] = []
	var grass_s: Array[Rect2] = []
	var grass_m: Array[Color] = []
	_tree_dest = []
	_tree_src = []
	_tree_mod = []
	_rock_dest = []
	_rock_src = []
	_rock_mod = []
	_decal_dest = []
	_decal_src = []
	_decal_mod = []
	_total = 0
	for idx in _geometry.islands.size():
		var isl: Rect2 = _geometry.islands[idx]
		if isl.size.x <= 2.0 * EDGE_MARGIN or isl.size.y <= 2.0 * EDGE_MARGIN:
			continue  # too small for the shoreline inset (defensive: _scatter would invert)
		var biome: int = _geometry.island_biomes[idx]
		var tint: Color = FOLIAGE_TINT[clampi(biome, 0, FOLIAGE_TINT.size() - 1)]
		# Own seeded rng per island (typed, never :=; type prewarmed by Session.warm()).
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = Session.seed ^ (idx * 0x9E3779B1)
		var area: float = isl.size.x * isl.size.y
		_scatter(rng, isl, TREE_CELLS, mini(TREE_CAP, int(area / TREE_AREA_PER)), 1.6, 2.6, tint, _tree_dest, _tree_src, _tree_mod)
		_scatter(rng, isl, GRASS_CELLS, mini(GRASS_CAP, int(area / GRASS_AREA_PER)), 0.8, 1.4, tint, grass_d, grass_s, grass_m)
		_scatter(rng, isl, ROCK_CELLS, mini(ROCK_CAP, int(area / ROCK_AREA_PER)), 0.8, 1.6, tint, _rock_dest, _rock_src, _rock_mod)
		# Decals draw LAST from the island's rng stream — appended after the three
		# original scatters so their placements stay identical for a given seed.
		_scatter(rng, isl, _decals_for(biome), mini(DECAL_CAP, int(area / DECAL_AREA_PER)), 0.7, 1.2, tint, _decal_dest, _decal_src, _decal_mod)
	_grass_layer.configure(FOLIAGE_TEX, grass_d, grass_s, grass_m, _grass_mat)
	_rebuild_trees()
	queue_redraw()   # rocks + decals

## Trees are individual Sprite2Ds (cap 120 — trivial node count) so each one can
## participate in the Playfield y-sort against players/monsters. Same placement
## data as the old batch draw; only the emission differs.
func _rebuild_trees() -> void:
	for s in _tree_sprites:
		s.queue_free()
	_tree_sprites = []
	var parent: Node2D = _tree_parent if _tree_parent != null else self
	for i in _tree_dest.size():
		var d: Rect2 = _tree_dest[i]
		var src: Rect2 = _tree_src[i]
		var sc: float = d.size.x / src.size.x
		var spr := Sprite2D.new()
		spr.texture = FOLIAGE_TEX
		spr.region_enabled = true
		spr.region_rect = src
		spr.centered = false
		spr.offset = Vector2(-src.size.x * 0.5, -src.size.y)  # root at the trunk base
		spr.scale = Vector2(sc, sc)
		spr.position = Vector2(d.position.x + d.size.x * 0.5, d.position.y + d.size.y)
		spr.material = _tree_mat
		spr.modulate = _tree_mod[i]
		parent.add_child(spr)
		_tree_sprites.append(spr)

func _decals_for(biome: int) -> Array[Vector2i]:
	match biome:
		BiomeRegistry.DESERT:
			return DECALS_DESERT
		BiomeRegistry.SNOW:
			return DECALS_SNOW
		BiomeRegistry.SWAMP:
			return DECALS_SWAMP
		BiomeRegistry.VOLCANO:
			return DECALS_VOLCANO
		BiomeRegistry.SAVANNA:
			return DECALS_SAVANNA
		_:
			return DECALS_FOREST

## Sample `count` instances of the given atlas `cells` inside `isl`, bottom-anchored at
## the sampled ground point, appending dest/src/tint into the parallel arrays. Honors
## the global cap.
func _scatter(rng: RandomNumberGenerator, isl: Rect2, cells: Array[Vector2i], count: int, smin: float, smax: float, tint: Color, dest: Array[Rect2], src: Array[Rect2], mod: Array[Color]) -> void:
	for _i in count:
		if _total >= GLOBAL_CAP:
			return
		var cell: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
		var sc: float = rng.randf_range(smin, smax)
		var px: float = rng.randf_range(isl.position.x + EDGE_MARGIN, isl.position.x + isl.size.x - EDGE_MARGIN)
		var py: float = rng.randf_range(isl.position.y + EDGE_MARGIN, isl.position.y + isl.size.y - EDGE_MARGIN)
		var w: float = float(CELL_W) * sc
		var h: float = float(CELL_H) * sc
		dest.append(Rect2(px - w * 0.5, py - h, w, h))   # bottom-center at (px, py)
		src.append(Rect2(cell.x * CELL_W, cell.y * CELL_H, CELL_W, CELL_H))
		mod.append(tint)
		_total += 1

func _make_mat(amp: float, spatial_k: float, base_v: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SWAY_SHADER
	m.set_shader_parameter("wind_phase", 0.0)
	m.set_shader_parameter("amp", amp)
	m.set_shader_parameter("spatial_k", spatial_k)
	m.set_shader_parameter("base_v", base_v)
	return m
