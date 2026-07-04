class_name CharAnim
## Layout contract for the baked character sheets (assets/sprites/{player,monster}.png)
## and helpers to map the sim's analog facing onto a 4-direction animation.
## Kept in sync with tools/art_baker.gd. Pure functions / consts — no nodes.
##
## Sheet: 16x24 frames, rows = DOWN/UP/SIDE (left = flip_h of SIDE),
## cols = idle(0-1) walk(2-5) attack(6-9).

const FRAME_W := 16
const FRAME_H := 24

# Sheet rows.
const ROW_DOWN := 0
const ROW_UP := 1
const ROW_SIDE := 2
const ROW_SUFFIX := ["down", "up", "side"]

# 4-direction facing the sim's Vector2 snaps to.
const FACE_DOWN := 0
const FACE_UP := 1
const FACE_LEFT := 2
const FACE_RIGHT := 3

## Snap an analog facing vector to one of the 4 cardinals (defaults to DOWN).
static func dir_from_facing(f: Vector2) -> int:
	if f.length() < 0.01:
		return FACE_DOWN
	if absf(f.x) > absf(f.y):
		return FACE_RIGHT if f.x > 0.0 else FACE_LEFT
	return FACE_DOWN if f.y > 0.0 else FACE_UP

static func row_for_face(face: int) -> int:
	match face:
		FACE_UP:
			return ROW_UP
		FACE_LEFT, FACE_RIGHT:
			return ROW_SIDE
		_:
			return ROW_DOWN

## SpriteFrames animation name for an action ("idle"/"walk"/"attack") + facing.
static func name_for(action: String, face: int) -> String:
	return "%s_%s" % [action, ROW_SUFFIX[row_for_face(face)]]
