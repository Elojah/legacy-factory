class_name EffectSpawner extends Node2D
## Client-only, cosmetic effect layer. Entities ask for an effect by id via their
## `effect_requested` signal; we map the id to a baked animation strip and spawn
## one generic SheetEffect at the requested world position/orientation.
## Extensible: add an EffectIds const + a `_registry` entry per new skill effect.
##
## ALL native resources (SpriteFrames / the shared additive CanvasItemMaterial /
## the projectile+hazard frame caches) are prebuilt here in _ready (a normal
## frame) so spawning — which can happen inside a snapshot/RPC handler — never
## constructs a native class via .new() in an RPC frame (the 4.7 bug; see
## CLAUDE.md). spawn() only instantiates a scene and assigns cached resources.

const SHEET_EFFECT := preload("res://entities/effects/sheet_effect.tscn")
const MAX_LIVE := 128   # defensive cap: volley spam must never flood the tree

# Shared caches for other visual shells (built here once, in a normal frame):
# projectiles and hazards instantiate INSIDE snapshot frames and must not build
# SpriteFrames themselves.
static var bolt_frames: SpriteFrames = null      # anim "fx" (loop) — bolt core
static var hazard_frames: SpriteFrames = null    # anim "swirl" (loop)
static var glow_tex: Texture2D = null            # radial white falloff
static var additive_mat: CanvasItemMaterial = null

var _registry: Dictionary = {}   # effect_id -> {frames, tint, scale, add, rot}

func _ready() -> void:
	additive_mat = CanvasItemMaterial.new()
	additive_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow_tex = load("res://assets/sprites/fx_glow.png")

	var slash := _strip("res://assets/sprites/fx_slash.png", 48, 48, 6, 24.0, false)
	var impact := _strip("res://assets/sprites/fx_impact.png", 24, 24, 5, 20.0, false)
	var dash := _strip("res://assets/sprites/fx_dash.png", 32, 32, 5, 18.0, false)
	var heal := _strip("res://assets/sprites/fx_heal.png", 32, 48, 8, 16.0, false)
	var ring := _strip("res://assets/sprites/fx_ring.png", 64, 64, 8, 20.0, false)
	var summon := _strip("res://assets/sprites/fx_summon.png", 48, 48, 7, 16.0, false)
	var charge := _strip("res://assets/sprites/fx_charge.png", 32, 32, 6, 12.0, false)
	bolt_frames = _strip("res://assets/sprites/fx_bolt.png", 16, 16, 4, 10.0, true)
	hazard_frames = _strip("res://assets/sprites/fx_hazard.png", 48, 48, 4, 8.0, true, "swirl")

	# The neutral white ring sheet expands to r=28 px; node scale maps it onto
	# each ability's sim radius. rot=false keeps radial/rising effects upright.
	_registry = {
		EffectIds.SLASH: _entry(slash, Color.WHITE, 1.0, false, true),
		EffectIds.BOLT_IMPACT: _entry(impact, Color(1.0, 0.82, 0.48), 1.0, true, true),
		EffectIds.DASH_PUFF: _entry(dash, Color(0.95, 0.97, 1.0), 1.0, false, true),
		EffectIds.HEAL_SPARKLE: _entry(heal, Color(0.42, 0.95, 0.55), 1.0, true, false),
		EffectIds.SLAM_RING: _entry(ring, Color(1.0, 0.6, 0.3), AbilityDefs.SLAM_RADIUS / 28.0, true, false),
		EffectIds.BOSS_SMASH_RING: _entry(ring, Color(1.0, 0.42, 0.24), AbilityDefs.SMASH_RADIUS / 28.0, true, false),
		EffectIds.BOSS_SUMMON_BURST: _entry(summon, Color(0.72, 0.47, 0.88), 1.2, false, false),
		EffectIds.NOVA_RING: _entry(ring, Color(0.55, 0.78, 1.0), AbilityDefs.NOVA_RADIUS / 28.0, true, false),
		EffectIds.BOSS_CHARGE_DUST: _entry(charge, Color(1.0, 0.95, 0.85), 1.6, false, true),
		EffectIds.MUZZLE_FLASH: _entry(impact, Color(1.0, 0.9, 0.6), 0.8, true, true),
	}

func _entry(frames: SpriteFrames, tint: Color, scl: float, add: bool, rot: bool) -> Dictionary:
	return {"frames": frames, "tint": tint, "scale": scl, "add": add, "rot": rot}

## Connect a freshly-created entity's effect_requested to us.
func bind(entity: GameEntity) -> void:
	entity.effect_requested.connect(spawn)

func spawn(effect_id: int, world_pos: Vector2, facing: Vector2) -> void:
	if not _registry.has(effect_id) or get_child_count() >= MAX_LIVE:
		return
	var e: Dictionary = _registry[effect_id]
	var fx := SHEET_EFFECT.instantiate() as SheetEffect
	add_child(fx)
	fx.configure(e["frames"], "fx", e["tint"], e["scale"], additive_mat if e["add"] else null)
	fx.global_position = world_pos
	if e["rot"] and facing.length() > 0.01:
		fx.rotation = facing.angle()

## Build a SpriteFrames holding one animation from a horizontal strip.
func _strip(path: String, fw: int, fh: int, n: int, fps: float, loop: bool, anim: String = "fx") -> SpriteFrames:
	var tex: Texture2D = load(path)
	var frames: SpriteFrames = SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation(anim)
	frames.set_animation_speed(anim, fps)
	frames.set_animation_loop(anim, loop)
	for i in n:
		var at: AtlasTexture = AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * fw, 0, fw, fh)
		frames.add_frame(anim, at)
	return frames
