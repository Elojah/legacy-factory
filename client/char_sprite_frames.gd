class_name CharSpriteFrames
## Builds and caches SpriteFrames for entity sprites. Monsters use one of three
## baked species sheets (slime/beetle/wisp — picked cosmetically per island biome
## by MonsterSkins); bosses use one of three bespoke 64x64 kit sheets (kit rides
## EntityState.appearance for bosses); players are baked AT RUNTIME by CharPainter
## from their Appearance code (class/hair/skin) and cached per sanitized code, so
## every look costs one 288x96 CPU bake, once. SpriteFrames are shareable across
## nodes (flip_h / frame are per-node). Frame geometry / column tables / fps all
## come from the CharPainter sheet contract (bosses have their own, below).
##
## warm() MUST be called once from a normal frame (client_world._ready) — NOT
## from inside a snapshot/RPC handler — because of the GDScript 4.7 bug where a
## native class first constructed via .new() inside an RPC-invoked frame fails to
## resolve (see CLAUDE.md). It pre-constructs every native type a later
## in-snapshot-frame bake needs (Image/ImageTexture/SpriteFrames/AtlasTexture),
## and preloads ALL species/boss sheets — monsters and bosses can first appear
## inside a snapshot frame.

# Boss sheet contract (tools/art_baker.gd _bake_boss): 640x128, frame 64x64,
# row 0 = FRONT (serves down AND up), row 1 = SIDE (left = flip_h),
# cols = idle(0-1) walk(2-5) attack(6-9).
const BOSS_FRAME := 64
const BOSS_IDLE_COLS: Array[int] = [0, 1]
const BOSS_WALK_COLS: Array[int] = [2, 3, 4, 5]
const BOSS_ATTACK_COLS: Array[int] = [6, 7, 8, 9]

# Index = MonsterSkins.SPECIES_* / BossDefs.KIT_* respectively.
const SPECIES_PATHS: Array[String] = [
	"res://assets/sprites/monster_slime.png",
	"res://assets/sprites/monster_beetle.png",
	"res://assets/sprites/monster_wisp.png",
]
const BOSS_PATHS: Array[String] = [
	"res://assets/sprites/boss_magma.png",
	"res://assets/sprites/boss_frost.png",
	"res://assets/sprites/boss_swamp.png",
]

static var _species_frames: Array = []   # species index -> SpriteFrames
static var _boss_frames: Array = []      # kit index -> SpriteFrames
static var _player_cache: Dictionary = {}  # sanitized appearance int -> SpriteFrames

static func warm() -> void:
	if _species_frames.is_empty():
		for path in SPECIES_PATHS:
			var tex: Texture2D = load(path)
			_species_frames.append(_build_from_texture(tex))
	if _boss_frames.is_empty():
		for path in BOSS_PATHS:
			var btex: Texture2D = load(path)
			_boss_frames.append(_build_boss_frames(btex))
	# Prewarm the runtime bake path: the default look and the local player's own.
	get_for(NetConfig.KIND_PLAYER, Appearance.DEFAULT)
	get_for(NetConfig.KIND_PLAYER, Session.appearance)

static func get_for(kind: int, appearance: int = 0, species: int = 0) -> SpriteFrames:
	if kind == NetConfig.KIND_MONSTER:
		if _species_frames.is_empty():
			warm()
		return _species_frames[clampi(species, 0, _species_frames.size() - 1)]
	if kind == NetConfig.KIND_BOSS:
		# Kit identity rides appearance for bosses (visual-only field).
		if _boss_frames.is_empty():
			warm()
		return _boss_frames[clampi(appearance, 0, _boss_frames.size() - 1)]
	var key: int = Appearance.sanitize(appearance)
	if not _player_cache.has(key):
		var img: Image = CharPainter.bake_sheet(key)
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		_player_cache[key] = _build_from_texture(tex)
	return _player_cache[key]

static func _build_from_texture(tex: Texture2D) -> SpriteFrames:
	var frames: SpriteFrames = SpriteFrames.new()
	frames.remove_animation("default")
	for row in CharPainter.ROWS:
		var suffix: String = CharAnim.ROW_SUFFIX[row]
		_add_anim(frames, tex, "idle_" + suffix, row, CharPainter.IDLE_COLS, CharPainter.IDLE_FPS, true)
		_add_anim(frames, tex, "walk_" + suffix, row, CharPainter.WALK_COLS, CharPainter.WALK_FPS, true)
		_add_anim(frames, tex, "attack_" + suffix, row, CharPainter.ATTACK_COLS, CharPainter.ATTACK_FPS, false)
	return frames

## Bosses register all six anim names too (so CharAnim.name_for output always
## resolves), but down/up both point at the FRONT strip (atlas row 0).
static func _build_boss_frames(tex: Texture2D) -> SpriteFrames:
	var frames: SpriteFrames = SpriteFrames.new()
	frames.remove_animation("default")
	for row in CharPainter.ROWS:
		var suffix: String = CharAnim.ROW_SUFFIX[row]
		var arow := 1 if row == CharAnim.ROW_SIDE else 0
		_add_anim(frames, tex, "idle_" + suffix, arow, BOSS_IDLE_COLS, 3.0, true, BOSS_FRAME, BOSS_FRAME)
		_add_anim(frames, tex, "walk_" + suffix, arow, BOSS_WALK_COLS, 7.0, true, BOSS_FRAME, BOSS_FRAME)
		_add_anim(frames, tex, "attack_" + suffix, arow, BOSS_ATTACK_COLS, 10.0, false, BOSS_FRAME, BOSS_FRAME)
	return frames

static func _add_anim(frames: SpriteFrames, tex: Texture2D, anim: String, row: int, cols: Array, fps: float, loop: bool, fw: int = CharAnim.FRAME_W, fh: int = CharAnim.FRAME_H) -> void:
	frames.add_animation(anim)
	frames.set_animation_speed(anim, fps)
	frames.set_animation_loop(anim, loop)
	for col in cols:
		var c: int = col
		var at: AtlasTexture = AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(c * fw, row * fh, fw, fh)
		frames.add_frame(anim, at)
