class_name FoliageLayer extends Node2D
## One batch of foliage sprites sharing a sway material (all trees, or all grass). A
## separate CanvasItem per material because a CanvasItem has a single material and trees
## / grass sway with different amplitudes. Foliage owns placement + the synced wind
## phase; this node only draws its precomputed dest/src/tint triples. Cosmetic only.

var _tex: Texture2D
var _dest: Array[Rect2] = []   # world-space destination rects (bottom-anchored)
var _src: Array[Rect2] = []    # atlas source cells (parallel to _dest)
var _mod: Array[Color] = []    # per-instance biome tint (parallel to _dest)

func configure(tex: Texture2D, dest: Array[Rect2], src: Array[Rect2], mod: Array[Color], mat: ShaderMaterial) -> void:
	_tex = tex
	_dest = dest
	_src = src
	_mod = mod
	material = mat
	queue_redraw()

func _draw() -> void:
	if _tex == null:
		return
	for i in _dest.size():
		draw_texture_rect_region(_tex, _dest[i], _src[i], _mod[i])
