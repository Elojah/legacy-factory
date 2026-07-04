class_name WaterLayer extends Node2D
## One material-homogeneous batch of water rects (all ponds, or all waterfalls). We
## need a separate CanvasItem per shader mode because a CanvasItem has a single
## material, so the two water looks (mode 0/1) cannot share one node. WaterRenderer
## owns placement and forwards the synced phase; this node only draws. Cosmetic only.

var _rects: Array[Rect2] = []
var _tex: Texture2D

## Assign this layer's rects, source texture and (mode-configured) material. The
## texture is a 1x1 white pixel stretched over each rect, so the shader colours it.
func configure(rects: Array[Rect2], tex: Texture2D, mat: ShaderMaterial) -> void:
	_rects = rects
	_tex = tex
	material = mat
	queue_redraw()

func _draw() -> void:
	if _tex == null:
		return
	for r in _rects:
		draw_texture_rect(_tex, r, false)
