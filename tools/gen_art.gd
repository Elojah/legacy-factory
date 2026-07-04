extends SceneTree
## Head-less entry point that bakes all placeholder pixel art into assets/.
## Not an EditorScript on purpose — this runs from the CLI with no GUI:
##   godot-4 --headless --path . --script res://tools/gen_art.gd
## Re-run any time the art needs regenerating; output is deterministic.

# preload (not the global class_name) so this works before a project class scan.
const ArtBakerScript := preload("res://tools/art_baker.gd")

func _initialize() -> void:
	print("[gen_art] _initialize start")
	var baker = ArtBakerScript.new()
	var failures: int = baker.bake_all()
	print("[gen_art] bake done, failures=%d" % failures)
	if failures > 0:
		printerr("[gen_art] %d asset(s) failed to write" % failures)
	else:
		print("[gen_art] all assets baked OK")
	quit(failures)
