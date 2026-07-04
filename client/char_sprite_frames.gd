class_name CharSpriteFrames
## Builds and caches SpriteFrames for entity sprites. Monsters use the one baked
## monster.png sheet; players are baked AT RUNTIME by CharPainter from their
## Appearance code (class/hair/skin) and cached per sanitized code, so every
## look costs one 160x72 CPU bake, once. SpriteFrames are shareable across
## nodes (flip_h / frame are per-node).
##
## warm() MUST be called once from a normal frame (client_world._ready) — NOT
## from inside a snapshot/RPC handler — because of the GDScript 4.7 bug where a
## native class first constructed via .new() inside an RPC-invoked frame fails to
## resolve (see CLAUDE.md). It pre-constructs every native type a later
## in-snapshot-frame bake needs (Image/ImageTexture/SpriteFrames/AtlasTexture);
## after that, baking an unseen remote appearance inside _on_snapshot is safe.

static var _monster_frames: SpriteFrames = null
static var _player_cache: Dictionary = {}  # sanitized appearance int -> SpriteFrames

static func warm() -> void:
	if _monster_frames == null:
		var tex: Texture2D = load("res://assets/sprites/monster.png")
		_monster_frames = _build_from_texture(tex)
	# Prewarm the runtime bake path: the default look and the local player's own.
	get_for(NetConfig.KIND_PLAYER, Appearance.DEFAULT)
	get_for(NetConfig.KIND_PLAYER, Session.appearance)

static func get_for(kind: int, appearance: int = 0) -> SpriteFrames:
	if kind == NetConfig.KIND_MONSTER or kind == NetConfig.KIND_BOSS:
		# Bosses share the monster sheet (MVP); node scale + kit tint make them huge.
		if _monster_frames == null:
			warm()
		return _monster_frames
	var key: int = Appearance.sanitize(appearance)
	if not _player_cache.has(key):
		var img: Image = CharPainter.bake_sheet(key)
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		_player_cache[key] = _build_from_texture(tex)
	return _player_cache[key]

static func _build_from_texture(tex: Texture2D) -> SpriteFrames:
	var frames: SpriteFrames = SpriteFrames.new()
	frames.remove_animation("default")
	for row in 3:
		var suffix: String = CharAnim.ROW_SUFFIX[row]
		_add_anim(frames, tex, "idle_" + suffix, row, [0, 1], 4.0, true)
		_add_anim(frames, tex, "walk_" + suffix, row, [2, 3, 4, 5], 9.0, true)
		_add_anim(frames, tex, "attack_" + suffix, row, [6, 7, 8, 9], 10.0, false)
	return frames

static func _add_anim(frames: SpriteFrames, tex: Texture2D, anim: String, row: int, cols: Array, fps: float, loop: bool) -> void:
	frames.add_animation(anim)
	frames.set_animation_speed(anim, fps)
	frames.set_animation_loop(anim, loop)
	for col in cols:
		var c: int = col
		var at: AtlasTexture = AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(c * CharAnim.FRAME_W, row * CharAnim.FRAME_H, CharAnim.FRAME_W, CharAnim.FRAME_H)
		frames.add_frame(anim, at)
