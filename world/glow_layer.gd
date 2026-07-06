class_name GlowLayer extends Node2D
## Additive light-glow quads over every luminous world point: resource orbs,
## waypoint runes, shrine sigils, boss banners, volcano lava pockets — plus
## village windows that only light up at night. Brightness scales with the
## night factor fed from client_world (the CanvasModulate darkens the world;
## these glows push back), so night reads alive instead of just dim.
##
## Anchors derive from the SAME geometry/derivations as MapMarkers (never the
## sim); lava pockets are seeded client-side per island on their own rng stream
## key so existing water/foliage streams don't shift. Uses draw_texture_rect
## only (the huge-coordinate polygon triangulation gotcha). Cosmetic only.

const GLOW_TEX := preload("res://assets/sprites/fx_glow.png")
const RUNE_COLOR := Color(0.55, 0.9, 1.0)
const WINDOW_COLOR := Color(1.0, 0.71, 0.42)
const LAVA_COLOR := Color(1.0, 0.48, 0.19)
const LAVA_STREAM_KEY := 0x85EBCA6B

var _geometry: WorldGeometry
var _taken_orbs: Dictionary = {}
var _night: float = 0.0
# Parallel arrays: always-on glows and night-only glows (village windows).
var _pos: Array[Vector2] = []
var _r: Array[float] = []
var _col: Array[Color] = []
var _npos: Array[Vector2] = []
var _nr: Array[float] = []
var _ncol: Array[Color] = []

func _ready() -> void:
	# Additive material built in a normal frame (the 4.7 native-.new() note).
	var m: CanvasItemMaterial = CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = m
	if _geometry != null:
		_rebuild()

func setup(geometry: WorldGeometry) -> void:
	_geometry = geometry
	_taken_orbs.clear()
	if is_node_ready():
		_rebuild()

## Night factor 0..1 from the synced day cycle (0 = noon, 1 = midnight),
## quantized so the redraw only fires when it visibly changes.
func set_night(f: float) -> void:
	var q := snappedf(clampf(f, 0.0, 1.0), 0.02)
	if q != _night:
		_night = q
		queue_redraw()

## Mirror of MapMarkers.set_pickup_taken (kind 0 = orb; caches have no glow —
## discovery is the mechanic).
func set_pickup_taken(kind: int, index: int, taken: bool) -> void:
	if kind != 0:
		return
	if taken:
		_taken_orbs[index] = true
	else:
		_taken_orbs.erase(index)
	if is_node_ready() and _geometry != null:
		_rebuild()

func _rebuild() -> void:
	_pos = []
	_r = []
	_col = []
	_npos = []
	_nr = []
	_ncol = []
	for i in _geometry.resources.size():
		if _taken_orbs.has(i):
			continue
		var t: int = _geometry.resource_tiers[i] if i < _geometry.resource_tiers.size() else 0
		_glow(_geometry.resources[i], 18.0 + 3.0 * float(t), MapMarkers.TIER_COLORS[clampi(t, 0, MapMarkers.TIER_COLORS.size() - 1)])
	for i in _geometry.villages.size():
		_glow(_geometry.villages[i] + Vector2(12, -4), 12.0, RUNE_COLOR)      # obelisk rune
		_night_glow(_geometry.villages[i] + Vector2(0, 2), 11.0, WINDOW_COLOR)  # hut window
	for p in _geometry.merchants:
		_glow(p + Vector2(-14, -4), 12.0, RUNE_COLOR)
	# Shrines: the same pure derivation as MapMarkers/Lobby (field islands >= 5,
	# non-boss, tier >= 1, at the island rect center).
	for i in range(5, _geometry.islands.size()):
		if i in _geometry.boss_islands or _geometry.island_tiers[i] < 1:
			continue
		var st: int = _geometry.island_tiers[i]
		_glow(_geometry.islands[i].get_center() + Vector2(0, -10), 22.0,
			MapMarkers.TIER_COLORS[clampi(st, 0, MapMarkers.TIER_COLORS.size() - 1)])
	for i in _geometry.boss_spawns.size():
		_glow(_geometry.boss_spawns[i] + Vector2(0, -10), 16.0, BossPalette.color_for(_geometry.boss_kits[i]))
	# Volcano lava pockets: seeded per island on a dedicated stream key.
	for idx in _geometry.islands.size():
		if _geometry.island_biomes[idx] != BiomeRegistry.VOLCANO:
			continue
		var isl: Rect2 = _geometry.islands[idx]
		if isl.size.x < 160.0 or isl.size.y < 160.0:
			continue
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = Session.seed ^ (idx * LAVA_STREAM_KEY)
		for _k in 4:
			var lx := rng.randf_range(isl.position.x + 70.0, isl.end.x - 70.0)
			var ly := rng.randf_range(isl.position.y + 70.0, isl.end.y - 70.0)
			_glow(Vector2(lx, ly), 15.0, LAVA_COLOR)
	queue_redraw()

func _glow(p: Vector2, radius: float, col: Color) -> void:
	_pos.append(p)
	_r.append(radius)
	_col.append(col)

func _night_glow(p: Vector2, radius: float, col: Color) -> void:
	_npos.append(p)
	_nr.append(radius)
	_ncol.append(col)

func _draw() -> void:
	var a := 0.22 + 0.5 * _night
	for i in _pos.size():
		var c: Color = _col[i]
		draw_texture_rect(GLOW_TEX, Rect2(_pos[i] - Vector2(_r[i], _r[i]), Vector2(_r[i] * 2.0, _r[i] * 2.0)),
			false, Color(c.r, c.g, c.b, a))
	var na := 0.75 * _night
	if na > 0.02:
		for i in _npos.size():
			var nc: Color = _ncol[i]
			draw_texture_rect(GLOW_TEX, Rect2(_npos[i] - Vector2(_nr[i], _nr[i]), Vector2(_nr[i] * 2.0, _nr[i] * 2.0)),
				false, Color(nc.r, nc.g, nc.b, na))
