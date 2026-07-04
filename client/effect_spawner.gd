class_name EffectSpawner extends Node2D
## Client-only, cosmetic effect layer. Entities ask for an effect by id via their
## `effect_requested` signal; we map the id to a scene and spawn a one-shot at the
## requested world position/orientation. Extensible: add an EffectIds const + an
## entry in `_registry` for each new skill effect.
##
## SpriteFrames are prebuilt here in _ready (a normal frame) so spawning — which
## can happen inside a snapshot/RPC handler — never constructs a native class via
## .new() in an RPC frame (the 4.7 bug; see CLAUDE.md). spawn() only instantiates
## a scene and assigns the cached frames.

var _registry: Dictionary = {}     # effect_id -> PackedScene
var _slash_frames: SpriteFrames

func _ready() -> void:
	_slash_frames = _build_slash_frames()
	var burst := preload("res://entities/effects/burst_effect.tscn")
	_registry = {
		EffectIds.SLASH: preload("res://entities/effects/slash_effect.tscn"),
		EffectIds.BOLT_IMPACT: burst,
		EffectIds.DASH_PUFF: burst,
		EffectIds.HEAL_SPARKLE: burst,
		EffectIds.SLAM_RING: burst,
		EffectIds.BOSS_SMASH_RING: burst,
		EffectIds.BOSS_SUMMON_BURST: burst,
		EffectIds.NOVA_RING: burst,
	}

## Connect a freshly-created entity's effect_requested to us.
func bind(entity: GameEntity) -> void:
	entity.effect_requested.connect(spawn)

func spawn(effect_id: int, world_pos: Vector2, facing: Vector2) -> void:
	if not _registry.has(effect_id):
		return
	var scene: PackedScene = _registry[effect_id]
	# Untyped on purpose: slash (AnimatedSprite2D) and burst (Node2D) one-shots.
	var fx = scene.instantiate()
	if fx is SlashEffect:
		fx.sprite_frames = _slash_frames
	else:
		fx.configure(effect_id)
	fx.global_position = world_pos
	fx.rotation = facing.angle() if facing.length() > 0.01 else 0.0
	add_child(fx)

func _build_slash_frames() -> SpriteFrames:
	var tex: Texture2D = load("res://assets/sprites/fx_slash.png")
	var frames: SpriteFrames = SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("slash")
	frames.set_animation_speed("slash", 24.0)
	frames.set_animation_loop("slash", false)
	for i in 5:
		var at: AtlasTexture = AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * 32, 0, 32, 32)
		frames.add_frame("slash", at)
	return frames
