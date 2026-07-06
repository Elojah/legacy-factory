class_name FloorRenderer extends Node2D
## Draws the walkable world (WorldGeometry.islands ++ bridges) as TILING textured
## rectangles instead of per-cell TileMap tiles. Islands are now hundreds to thousands
## of tiles wide (millions of cells) — far too many to paint individually — so each
## island/bridge is just a handful of draw calls regardless of size:
##   * a soft layered drop shadow + a rocky rim and a reverse-pyramid rock mass hanging
##     underneath, so islands read as FLOATING chunks of land in the sky;
##   * a biome floor texture tiled across the rect (draw_texture_rect(tile=true));
##   * bridges get a wooden-plank texture with rope rails instead of a plain floor.
## Built from the SAME geometry the sim collides against (WorldGeometry.walkable), so
## the picture and the collision stay in sync. Cosmetic only; never feeds the sim.

const TS := BiomeRegistry.TILE_SIZE   # 16 px/tile

# Floating-island look (world px).
const SHADOW_OFFSET := Vector2(20, 34)          # drop-shadow displacement (scaled for small islands)
const SHADOW_LAYERS := 3                         # stacked translucent rects = fake blur
const SHADOW_SPREAD := 10.0                      # each layer grows this much more
const SHADOW_ALPHA := 0.22                       # base alpha of the tightest shadow layer
const RIM_PX := 12.0                             # rocky cliff band hugging the plateau edge
const PYRAMID_BANDS := 5                          # rock bands hanging below an island
const BAND_H := 16.0                             # height of each hanging band (px)
const BAND_INSET_STEP := 26.0                    # each band narrows this much per side, going down
const EDGE_COLOR := Color(1.0, 1.0, 1.0, 0.14)   # thin top-lip highlight
const RIM_SUN_COLOR := Color(1.0, 1.0, 1.0, 0.18)  # sun-lit band at the very top of the rim
const AO_COLOR := Color(0.0, 0.0, 0.0, 0.14)     # soft inner ambient-occlusion band
const AO_PX := 6.0
# Fixed pseudo-random 4x4 arrangement of the 4 floor variants — kills the visible
# 2x2 checker while staying deterministic and seamlessly tileable (64x64).
const FLOOR_MIX: Array[int] = [0, 1, 2, 1, 0, 0, 1, 2, 1, 2, 0, 3, 2, 1, 0, 0]

# Per-biome tint applied to the neutral wood plank tile (subtle, stays wood-coloured).
const BIOME_TINT: Array[Color] = [
	Color(0.90, 1.00, 0.85), Color(1.00, 0.95, 0.80), Color(0.90, 0.95, 1.00),
	Color(0.85, 0.95, 0.80), Color(1.00, 0.85, 0.80), Color(1.00, 0.98, 0.80),
]

var _geometry: WorldGeometry
var _floor_tex: Array = []   # biome index -> ImageTexture (64x64 variant patchwork)
var _rim_tex: Array = []     # biome index -> ImageTexture (16x16 cliff face, atlas col 4)
var _edge_tex: Array = []    # biome index -> ImageTexture (16x16 overhang fringe, col 5)
var _bridge_tex: Texture2D   # shared 16x16 wood-plank tile

func _ready() -> void:
	# Repeat is required for draw_texture_rect(tile=true) to actually tile.
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# Build textures in a normal frame (never inside a snapshot/RPC handler — the 4.7
	# native-.new() note in CLAUDE.md). Reuses the baked terrain/bridge assets.
	_build_floor_textures()
	_build_rim_textures()
	_bridge_tex = load("res://assets/tiles/bridge.png")
	if _geometry != null:
		queue_redraw()

## Compose one tileable 64x64 patchwork texture per biome from the 4 floor variant
## tiles in the fixed FLOOR_MIX arrangement — varied ground with no visible checker.
func _build_floor_textures() -> void:
	var atlas: Image = load("res://assets/tiles/terrain.png").get_image()
	if atlas.is_compressed():
		atlas.decompress()
	atlas.convert(Image.FORMAT_RGBA8)
	for b in BiomeRegistry.BIOME_COUNT:
		var img := Image.create_empty(TS * 4, TS * 4, false, Image.FORMAT_RGBA8)
		for i in FLOOR_MIX.size():
			var vc := BiomeRegistry.floor_var_coord(b, FLOOR_MIX[i])
			var cell := Vector2i((i % 4) * TS, (i >> 2) * TS)
			img.blit_rect(atlas, Rect2i(vc.x * TS, vc.y * TS, TS, TS), cell)
		_floor_tex.append(ImageTexture.create_from_image(img))

## Slice the terrain atlas cliff column (BiomeRegistry.wall_coord) into one 16x16
## tileable rock-face texture per biome (island rims / reverse-pyramid bands), and
## the edge column into the overhang fringe strip.
func _build_rim_textures() -> void:
	var atlas: Image = load("res://assets/tiles/terrain.png").get_image()
	if atlas.is_compressed():
		atlas.decompress()
	atlas.convert(Image.FORMAT_RGBA8)
	for b in BiomeRegistry.BIOME_COUNT:
		var cc := BiomeRegistry.wall_coord(b)
		var img := Image.create_empty(TS, TS, false, Image.FORMAT_RGBA8)
		img.blit_rect(atlas, Rect2i(cc.x * TS, cc.y * TS, TS, TS), Vector2i(0, 0))
		_rim_tex.append(ImageTexture.create_from_image(img))
		var ec := BiomeRegistry.edge_coord(b)
		var eimg := Image.create_empty(TS, TS, false, Image.FORMAT_RGBA8)
		eimg.blit_rect(atlas, Rect2i(ec.x * TS, ec.y * TS, TS, TS), Vector2i(0, 0))
		_edge_tex.append(ImageTexture.create_from_image(eimg))

func setup(geometry: WorldGeometry) -> void:
	_geometry = geometry
	queue_redraw()

func _draw() -> void:
	if _geometry == null or _floor_tex.is_empty():
		return
	# Pass 1: undersides (shadow + rocky rim + hanging pyramid) for ALL rects first, so a
	# neighbour's rim never buries an adjacent floor. Islands get the full pyramid; bridges
	# get only a thin shadow + rim (a heavy mass under a narrow catwalk looks wrong).
	for i in _geometry.islands.size():
		_draw_underside(_geometry.islands[i], _geometry.island_biomes[i], false)
	for j in _geometry.bridges.size():
		_draw_underside(_geometry.bridges[j], _geometry.bridge_biomes[j], true)
	# Pass 2: tiled biome floors (islands) / plank decks (bridges) on top.
	for i in _geometry.islands.size():
		_draw_floor(_geometry.islands[i], _geometry.island_biomes[i])
	for j in _geometry.bridges.size():
		_draw_bridge(_geometry.bridges[j], _geometry.bridge_biomes[j])

## Shadow + rocky rim (+ reverse-pyramid rock mass for islands). `thin` bridges skip
## the pyramid. Uses only draw_rect / draw_texture_rect (triangulation-safe at the huge
## island coordinates — never draw_colored_polygon).
func _draw_underside(rect: Rect2, biome: int, thin: bool) -> void:
	# Soft, layered drop shadow: stacked translucent rects approximate a blur.
	for i in SHADOW_LAYERS:
		var grow: float = float(i) * SHADOW_SPREAD
		var a: float = SHADOW_ALPHA * (1.0 - float(i) / float(SHADOW_LAYERS))
		draw_rect(Rect2(rect.position + SHADOW_OFFSET, rect.size).grow(grow), Color(0.0, 0.0, 0.0, a), true)
	var cliff: Texture2D = _rim_tex[clampi(biome, 0, _rim_tex.size() - 1)]
	# Rocky rim hugging the plateau edge (the floor draws over the interior in pass 2).
	draw_texture_rect(cliff, rect.grow(RIM_PX), true)
	# Sun-lit band at the very top of the rim so plateaus pop against the sky.
	draw_rect(Rect2(rect.position + Vector2(-RIM_PX, -RIM_PX), Vector2(rect.size.x + 2.0 * RIM_PX, 3.0)), RIM_SUN_COLOR, true)
	if thin:
		return
	# Reverse-pyramid rock mass hanging beneath the island: each band is lower and
	# narrower (inset per side), and darker, so the underside tapers into shadow.
	for i in PYRAMID_BANDS:
		var inset: float = RIM_PX + float(i) * BAND_INSET_STEP
		var band_w: float = rect.size.x - 2.0 * inset
		if band_w <= float(TS):
			break
		var by: float = rect.position.y + rect.size.y - 2.0 + float(i) * BAND_H
		var band := Rect2(rect.position.x + inset, by, band_w, BAND_H + 2.0)
		var shade: float = 1.0 - 0.13 * float(i + 1)   # recede into darkness lower down
		draw_texture_rect(cliff, band, true, Color(shade, shade, shade, 1.0))

func _draw_floor(rect: Rect2, biome: int) -> void:
	var b := clampi(biome, 0, _floor_tex.size() - 1)
	var tex: Texture2D = _floor_tex[b]
	draw_texture_rect(tex, rect, true)   # tile=true repeats the 64x64 patchwork
	# Soft ambient-occlusion band along the inner edges grounds the plateau.
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, AO_PX)), AO_COLOR, true)
	draw_rect(Rect2(Vector2(rect.position.x, rect.end.y - AO_PX), Vector2(rect.size.x, AO_PX)), AO_COLOR, true)
	draw_rect(Rect2(Vector2(rect.position.x, rect.position.y + AO_PX), Vector2(AO_PX, rect.size.y - 2.0 * AO_PX)), AO_COLOR, true)
	draw_rect(Rect2(Vector2(rect.end.x - AO_PX, rect.position.y + AO_PX), Vector2(AO_PX, rect.size.y - 2.0 * AO_PX)), AO_COLOR, true)
	# A thin lighter lip along the top edge so the plateau reads against the sky.
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 2.0)), EDGE_COLOR, true)
	# Grass-overhang fringe along the bottom edge: the strip's top 4 rows overlap the
	# floor seamlessly, the ragged blades hang over the cliff rim below.
	var edge: Texture2D = _edge_tex[b]
	draw_texture_rect(edge, Rect2(Vector2(rect.position.x, rect.end.y - 4.0), Vector2(rect.size.x, float(TS))), true)

## A bridge deck: wooden planks tiled across the span (tinted toward the parent biome)
## with rope rails + worn edges along the two long sides. Orientation from the aspect.
func _draw_bridge(rect: Rect2, biome: int) -> void:
	var tint: Color = BIOME_TINT[clampi(biome, 0, BIOME_TINT.size() - 1)]
	draw_texture_rect(_bridge_tex, rect, true, tint)
	var rail := Color(0.85, 0.78, 0.55, 0.9)
	var worn := Color(0.0, 0.0, 0.0, 0.22)
	if rect.size.x >= rect.size.y:   # horizontal arm: rails run along the top/bottom edges
		draw_line(rect.position, rect.position + Vector2(rect.size.x, 0.0), rail, 1.0)
		draw_line(rect.position + Vector2(0.0, rect.size.y), rect.position + rect.size, rail, 1.0)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, 2.0)), worn, true)
		draw_rect(Rect2(rect.position + Vector2(0.0, rect.size.y - 2.0), Vector2(rect.size.x, 2.0)), worn, true)
	else:                            # vertical arm: rails run along the left/right edges
		draw_line(rect.position, rect.position + Vector2(0.0, rect.size.y), rail, 1.0)
		draw_line(rect.position + Vector2(rect.size.x, 0.0), rect.position + rect.size, rail, 1.0)
		draw_rect(Rect2(rect.position, Vector2(2.0, rect.size.y)), worn, true)
		draw_rect(Rect2(rect.position + Vector2(rect.size.x - 2.0, 0.0), Vector2(2.0, rect.size.y)), worn, true)
