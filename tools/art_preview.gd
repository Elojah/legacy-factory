extends Node2D
## Static art showcase used to eyeball / screenshot the graphics without a server.
## Loaded by Bootstrap on `--preview`. Builds a real procedural world (so the enriched
## terrain, floating-island undersides + reverse-pyramid stones, waterfalls/ponds and
## swaying foliage all render), stages a row of posed characters + a couple of slash
## effects on the first island, captures the viewport to user://art_preview*.png and
## quits. Cosmetic only — runs no simulation. NOTE: needs a real display to capture;
## `--headless` renders blank (see the godot-headless-dev-workflow memory).

const PLAYER_SCENE := preload("res://entities/player.tscn")
const MONSTER_SCENE := preload("res://entities/monster.tscn")
const TEST_MAP := preload("res://world/test_map.tscn")

const PREVIEW_SEED := 4242

var _effects: EffectSpawner
var _cam: Camera2D
var _map: TestMap
var _stage: Vector2   # island-center where characters are posed

func _ready() -> void:
	# Session drives the client-side water/foliage scatter (seed) — set it before render.
	Session.seed = PREVIEW_SEED
	Session.size = WorldGenerator.SIZE_SMALL
	var geo := WorldGenerator.generate(PREVIEW_SEED, WorldGenerator.SIZE_SMALL)

	_map = TEST_MAP.instantiate()
	add_child(_map)
	_map.render(geo)
	# Fixed cosmetic phases so water/foliage render statically for the screenshot.
	_map.set_water_phase(0.30)
	_map.set_wind_phase(0.20)

	_effects = EffectSpawner.new()
	add_child(_effects)

	_cam = Camera2D.new()
	add_child(_cam)
	_cam.make_current()

	# Pose characters on the first island so they sit on real terrain, not empty sky.
	var isl: Rect2 = geo.islands[0]
	_stage = isl.position + isl.size * 0.5

	# Top row: players. Bottom row: monsters. Columns: idle-down, walk-right,
	# attack-down, attack-right, idle-up.
	var y_top := -90.0
	var y_bot := 90.0
	var xs := [-360.0, -200.0, -40.0, 140.0, 320.0]

	_spawn(NetConfig.KIND_PLAYER, Vector2(xs[0], y_top), Vector2.DOWN, "idle", GameEntity.MODE_LOCAL, 100)
	_spawn(NetConfig.KIND_PLAYER, Vector2(xs[1], y_top), Vector2.RIGHT, "walk", GameEntity.MODE_REMOTE, 100)
	_spawn(NetConfig.KIND_PLAYER, Vector2(xs[2], y_top), Vector2.DOWN, "attack", GameEntity.MODE_LOCAL, 70)
	_spawn(NetConfig.KIND_PLAYER, Vector2(xs[3], y_top), Vector2.RIGHT, "attack", GameEntity.MODE_LOCAL, 100)
	_spawn(NetConfig.KIND_PLAYER, Vector2(xs[4], y_top), Vector2.UP, "idle", GameEntity.MODE_REMOTE, 100)

	_spawn(NetConfig.KIND_MONSTER, Vector2(xs[0], y_bot), Vector2.DOWN, "idle", GameEntity.MODE_REMOTE, 120)
	_spawn(NetConfig.KIND_MONSTER, Vector2(xs[1], y_bot), Vector2.LEFT, "walk", GameEntity.MODE_REMOTE, 120)
	_spawn(NetConfig.KIND_MONSTER, Vector2(xs[2], y_bot), Vector2.DOWN, "attack", GameEntity.MODE_REMOTE, 120)
	_spawn(NetConfig.KIND_MONSTER, Vector2(xs[3], y_bot), Vector2.LEFT, "attack", GameEntity.MODE_REMOTE, 60)
	_spawn(NetConfig.KIND_MONSTER, Vector2(xs[4], y_bot), Vector2.UP, "idle", GameEntity.MODE_REMOTE, 120)

	_capture(geo)

func _spawn(kind: int, offset: Vector2, facing: Vector2, action: String, mode: int, hp: int) -> void:
	var pos := _stage + offset
	var st := EntityState.new()
	st.kind = kind
	st.pos = pos
	st.facing = facing
	st.hp = hp
	if action == "walk":
		st.vel = facing * 100.0
	elif action == "attack":
		st.ability_id = AbilityDefs.MELEE
		st.ability_phase = Ability.PHASE_ACTIVE
		st.ability_timer = AbilityDefs.ACTIVE_TICKS[AbilityDefs.MELEE]
	var scene := MONSTER_SCENE if kind == NetConfig.KIND_MONSTER else PLAYER_SCENE
	var node := scene.instantiate() as GameEntity
	node.setup(st, mode)
	add_child(node)
	if action == "attack":
		node.get_node("Sprite").frame = 2  # strike frame
		var origin := pos + facing.normalized() * (NetConfig.ENTITY_RADIUS + AbilityDefs.MELEE_RANGE * 0.5)
		_effects.spawn(EffectIds.SLASH, origin, facing)

func _capture(geo: WorldGeometry) -> void:
	for i in geo.islands.size():
		var r: Rect2 = geo.islands[i]
		print("[art_preview] island %d biome=%d rect=%s" % [i, geo.island_biomes[i], str(r)])
	print("[art_preview] bridges=%d stage=%s" % [geo.bridges.size(), str(_stage)])

	# A wide overview of the whole small map (islands, bridges, water, foliage).
	_cam.position = geo.bounds.position + geo.bounds.size * 0.5
	var span: float = maxf(geo.bounds.size.x, geo.bounds.size.y)
	var vp: float = maxf(1.0, get_viewport().get_visible_rect().size.x)
	_cam.zoom = Vector2.ONE * clampf(vp / span, 0.02, 1.0)
	await _shoot("user://art_preview.png")

	# Close-up on the posed characters (island[0] centre).
	_cam.zoom = Vector2(2.0, 2.0)
	_cam.position = _stage
	await _shoot("user://art_preview_zoom.png")

	# The full bottom edge of island[0] zoomed out: shows the reverse-pyramid undersides +
	# hanging waterfalls spilling into the sky gap, with floor/foliage above the lip.
	var isl: Rect2 = geo.islands[0]
	_cam.zoom = Vector2(0.16, 0.16)
	_cam.position = Vector2(isl.position.x + isl.size.x * 0.5, isl.position.y + isl.size.y - 200.0)
	await _shoot("user://art_preview_edge.png")

	# An interior patch of island[0] at native zoom: floor detail + foliage.
	_cam.zoom = Vector2(1.0, 1.0)
	_cam.position = Vector2(isl.position.x + isl.size.x * 0.5, isl.position.y + isl.size.y * 0.5)
	await _shoot("user://art_preview_foliage.png")
	get_tree().quit()

func _shoot(path: String) -> void:
	# Let the map + sprites draw complete frames before reading back.
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[art_preview] saved %s (err=%d) -> %s" % [path, err, OS.get_user_data_dir()])
