class_name SheetEffect extends AnimatedSprite2D
## The one generic one-shot effect node: plays a baked animation strip once and
## frees itself. EffectSpawner instantiates it (scene instantiation is safe in
## snapshot/RPC frames), positions/rotates it, and calls configure() with a
## PREBUILT SpriteFrames + optional shared additive material — this script never
## constructs a native class itself (the 4.7 native-.new()-in-RPC-frame gotcha).

func configure(frames: SpriteFrames, anim: String, tint: Color, scl: float, mat: Material) -> void:
	sprite_frames = frames
	modulate = tint
	scale = Vector2(scl, scl)
	if mat != null:
		material = mat
	animation_finished.connect(queue_free)
	play(anim)
