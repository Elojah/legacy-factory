class_name SlashEffect extends AnimatedSprite2D
## A one-shot cosmetic slash. EffectSpawner sets sprite_frames (prebuilt), our
## world position and rotation, then adds us to the tree; we play once and free
## ourselves. Purely visual — no sim coupling.

func _ready() -> void:
	centered = true
	animation_finished.connect(queue_free)
	play("slash")
