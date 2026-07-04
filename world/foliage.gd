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

# Atlas layout (assets/tiles/foliage.png = 6 cells of 16x24; see tools/art_baker.gd).
const CELL_W := 16
const CELL_H := 24
const TREE_CELLS: Array[int] = [0, 1, 2]
const GRASS_CELLS: Array[int] = [3]
const ROCK_CELLS: Array[int] = [4, 5]

# Density (1 instance per this many world px^2) + per-island and global caps.
# Tuned for the SMALL islands (384-1024 px edges): a min island gets ~1 tree /
# ~5 grass, a max one ~8 trees / ~35 grass / ~4 rocks.
const TREE_AREA_PER := 120000.0
const GRASS_AREA_PER := 30000.0
const ROCK_AREA_PER := 250000.0
const TREE_CAP := 120
const GRASS_CAP := 500
const ROCK_CAP := 60
const GLOBAL_CAP := 3000
const EDGE_MARGIN := 48.0     # keep foliage off the shoreline

# Subtle per-biome tint (multiplied onto the natural sprite colours via modulate).
const FOLIAGE_TINT: Array[Color] = [
	Color(1.00, 1.00, 1.00), Color(1.00, 0.90, 0.65), Color(0.85, 0.92, 1.00),
	Color(0.80, 0.90, 0.70), Color(0.90, 0.75, 0.70), Color(1.00, 0.95, 0.60),
]

var _geometry: WorldGeometry
var _tree_layer: FoliageLayer
var _grass_layer: FoliageLayer
var _tree_mat: ShaderMaterial
var _grass_mat: ShaderMaterial
var _rock_dest: Array[Rect2] = []
var _rock_src: Array[Rect2] = []
var _rock_mod: Array[Color] = []
var _total := 0

func _ready() -> void:
	# Build the sway materials in a normal frame (the 4.7 native-.new() note). Grass
	# sways more than trees; both share one shader with different amp.
	_grass_mat = _make_mat(2.6, 0.020)
	_tree_mat = _make_mat(2.0, 0.012)
	_grass_layer = FoliageLayer.new()
	_tree_layer = FoliageLayer.new()
	add_child(_grass_layer)   # drawn under the trees
	add_child(_tree_layer)
	if _geometry != null:
		_rebuild()

func setup(geometry: WorldGeometry) -> void:
	_geometry = geometry
	if is_node_ready():
		_rebuild()

## Push the synchronized wind phase to both sway materials (called each frame by
## client_world, mirroring sky.gd / water_renderer).
func set_wind_phase(p: float) -> void:
	if _grass_mat != null:
		_grass_mat.set_shader_parameter("wind_phase", p)
	if _tree_mat != null:
		_tree_mat.set_shader_parameter("wind_phase", p)

func _draw() -> void:
	# Rocks: static (no material), drawn by the parent so they sit under the foliage.
	for i in _rock_dest.size():
		draw_texture_rect_region(FOLIAGE_TEX, _rock_dest[i], _rock_src[i], _rock_mod[i])

func _rebuild() -> void:
	var tree_d: Array[Rect2] = []
	var tree_s: Array[Rect2] = []
	var tree_m: Array[Color] = []
	var grass_d: Array[Rect2] = []
	var grass_s: Array[Rect2] = []
	var grass_m: Array[Color] = []
	_rock_dest = []
	_rock_src = []
	_rock_mod = []
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
		_scatter(rng, isl, TREE_CELLS, mini(TREE_CAP, int(area / TREE_AREA_PER)), 1.6, 2.6, tint, tree_d, tree_s, tree_m)
		_scatter(rng, isl, GRASS_CELLS, mini(GRASS_CAP, int(area / GRASS_AREA_PER)), 0.8, 1.4, tint, grass_d, grass_s, grass_m)
		_scatter(rng, isl, ROCK_CELLS, mini(ROCK_CAP, int(area / ROCK_AREA_PER)), 0.8, 1.6, tint, _rock_dest, _rock_src, _rock_mod)
	_grass_layer.configure(FOLIAGE_TEX, grass_d, grass_s, grass_m, _grass_mat)
	_tree_layer.configure(FOLIAGE_TEX, tree_d, tree_s, tree_m, _tree_mat)
	queue_redraw()   # rocks

## Sample `count` instances of the given atlas `cells` inside `isl`, bottom-anchored at
## the sampled ground point, appending dest/src/tint into the parallel arrays. Honors
## the global cap.
func _scatter(rng: RandomNumberGenerator, isl: Rect2, cells: Array[int], count: int, smin: float, smax: float, tint: Color, dest: Array[Rect2], src: Array[Rect2], mod: Array[Color]) -> void:
	for _i in count:
		if _total >= GLOBAL_CAP:
			return
		var cell: int = cells[rng.randi_range(0, cells.size() - 1)]
		var sc: float = rng.randf_range(smin, smax)
		var px: float = rng.randf_range(isl.position.x + EDGE_MARGIN, isl.position.x + isl.size.x - EDGE_MARGIN)
		var py: float = rng.randf_range(isl.position.y + EDGE_MARGIN, isl.position.y + isl.size.y - EDGE_MARGIN)
		var w: float = float(CELL_W) * sc
		var h: float = float(CELL_H) * sc
		dest.append(Rect2(px - w * 0.5, py - h, w, h))   # bottom-center at (px, py)
		src.append(Rect2(cell * CELL_W, 0, CELL_W, CELL_H))
		mod.append(tint)
		_total += 1

func _make_mat(amp: float, spatial_k: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SWAY_SHADER
	m.set_shader_parameter("wind_phase", 0.0)
	m.set_shader_parameter("amp", amp)
	m.set_shader_parameter("spatial_k", spatial_k)
	return m
