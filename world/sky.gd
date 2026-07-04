extends ColorRect
## Thin driver for the procedural sky shader (world/sky.gdshader). Lives on the
## full-viewport SkyRect inside the Sky CanvasLayer (behind the world). client_world
## feeds it a synchronized time-of-day, a cloud-scroll phase, the camera offset (for
## parallax) and the viewport size each frame — this keeps client_world decoupled from
## the shader's uniform names. Cosmetic only; never touches the sim.

@onready var _mat: ShaderMaterial = material as ShaderMaterial

func set_params(time_of_day: float, cloud_phase: float, cam_offset: Vector2, res: Vector2) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("time_of_day", time_of_day)
	_mat.set_shader_parameter("cloud_phase", cloud_phase)
	_mat.set_shader_parameter("cam_offset", cam_offset)
	_mat.set_shader_parameter("resolution", res)
