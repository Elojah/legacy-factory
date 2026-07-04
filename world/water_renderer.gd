class_name WaterRenderer extends Node2D
## Cosmetic animated water for the floating-islands world: on-island ponds + waterfalls
## spilling off island bottom edges into the sky. Two child WaterLayers (one per shader
## mode) draw the features; a synced `water_phase` — fed by client_world from the
## GameClock, exactly like the sky — animates the flow with zero extra network traffic.
##
## Placement is derived CLIENT-SIDE from the lobby seed and NEVER touches the sim or the
## WorldGeometry: ponds are purely visual (players walk over them; the sim's only "water"
## is the impassable gap around islands). All clients in a lobby share Session.seed, so
## they also happen to see identical water — a free bonus, not a requirement.

const WATER_SHADER := preload("res://world/water.gdshader")

const PONDS_PER_ISLAND_MAX := 2
const FALLS_PER_ISLAND_MAX := 2
const POND_MIN := 48.0
const POND_MAX := 140.0
const FALL_W_MIN := 24.0
const FALL_W_MAX := 60.0
const FALL_DROP_MIN := 120.0
const FALL_DROP_MAX := 210.0
const EDGE_MARGIN := 40.0     # keep ponds/falls off the very shoreline

var _geometry: WorldGeometry
var _white: Texture2D
var _ponds: WaterLayer
var _falls: WaterLayer
var _pond_mat: ShaderMaterial
var _fall_mat: ShaderMaterial

func _ready() -> void:
	# Build native resources (Image/ImageTexture/ShaderMaterial) in a normal frame,
	# never inside a snapshot/RPC handler — the 4.7 native-.new() note in CLAUDE.md.
	_white = _make_white()
	_pond_mat = _make_mat(0, Color(0.25, 0.55, 0.85, 0.80))
	_fall_mat = _make_mat(1, Color(0.55, 0.78, 0.95, 0.85))
	_ponds = WaterLayer.new()
	_falls = WaterLayer.new()
	add_child(_ponds)
	add_child(_falls)
	if _geometry != null:
		_rebuild()

func setup(geometry: WorldGeometry) -> void:
	_geometry = geometry
	if is_node_ready():
		_rebuild()

## Push the synchronized flow phase to both layer materials (called each frame by
## client_world, mirroring how sky.gd is fed).
func set_phase(p: float) -> void:
	if _pond_mat != null:
		_pond_mat.set_shader_parameter("water_phase", p)
	if _fall_mat != null:
		_fall_mat.set_shader_parameter("water_phase", p)

func _rebuild() -> void:
	var ponds: Array[Rect2] = []
	var falls: Array[Rect2] = []
	for idx in _geometry.islands.size():
		var isl: Rect2 = _geometry.islands[idx]
		# Own seeded rng per island (typed, never :=; type prewarmed by Session.warm()).
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = Session.seed * 1000003 + idx
		# Ponds inside the island, inset from the shoreline. Islands are SMALL now:
		# clamp feature sizes to the available inset span BEFORE drawing a position
		# (an inverted randf_range would scatter the pond off-island) and skip the
		# island entirely when even POND_MIN doesn't fit. Each island has its own
		# rng, so a skip can never shift another island's draws.
		var avail_x: float = isl.size.x - 2.0 * EDGE_MARGIN
		var avail_y: float = isl.size.y - 2.0 * EDGE_MARGIN
		var n_ponds: int = rng.randi_range(0, PONDS_PER_ISLAND_MAX)
		if minf(avail_x, avail_y) >= POND_MIN:
			for _p in n_ponds:
				var w: float = minf(rng.randf_range(POND_MIN, POND_MAX), avail_x)
				var h: float = minf(rng.randf_range(POND_MIN, POND_MAX) * 0.6, avail_y)
				var x: float = rng.randf_range(isl.position.x + EDGE_MARGIN, isl.position.x + isl.size.x - EDGE_MARGIN - w)
				var y: float = rng.randf_range(isl.position.y + EDGE_MARGIN, isl.position.y + isl.size.y - EDGE_MARGIN - h)
				if w > 0.0 and h > 0.0:
					ponds.append(Rect2(x, y, w, h))
		# Waterfalls spilling off the island's bottom edge into the sky gap below.
		var n_falls: int = rng.randi_range(1, FALLS_PER_ISLAND_MAX)
		if avail_x >= FALL_W_MIN:
			for _f in n_falls:
				var fw: float = minf(rng.randf_range(FALL_W_MIN, FALL_W_MAX), avail_x)
				var fx: float = rng.randf_range(isl.position.x + EDGE_MARGIN, isl.position.x + isl.size.x - EDGE_MARGIN - fw)
				var drop: float = rng.randf_range(FALL_DROP_MIN, FALL_DROP_MAX)
				var fy: float = isl.position.y + isl.size.y - 6.0   # start just under the lip
				falls.append(Rect2(fx, fy, fw, drop))
	_ponds.configure(ponds, _white, _pond_mat)
	_falls.configure(falls, _white, _fall_mat)

func _make_white() -> Texture2D:
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	return ImageTexture.create_from_image(img)

func _make_mat(mode: int, tint: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = WATER_SHADER
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("water_phase", 0.0)
	return m
