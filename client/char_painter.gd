class_name CharPainter extends RefCounted
## The single humanoid sprite-sheet painter, parameterized by an Appearance code.
## Extracted from tools/art_baker.gd so the client can bake a sheet AT RUNTIME for
## any (class, hair style, hair color, skin tone) combination — a 160x72 image is
## trivial CPU work — instead of pre-baking every combination as a PNG. ArtBaker
## still calls bake_sheet(0) to emit the default assets/sprites/player.png, and
## Appearance.DEFAULT (0) must reproduce that original sheet byte-identically.
##
## Sheet contract (kept in sync with client/char_anim.gd + tools/art_baker.gd):
##   160x72, frame 16x24, rows = DOWN/UP/SIDE, cols = idle(0-1) walk(2-5) attack(6-9)
##
## Pure deterministic image math — no nodes, no randomness. Native constructions
## are explicitly typed (never `:=`) and first happen in normal frames via
## CharSpriteFrames.warm(), per the 4.7 native-.new()-in-RPC-frame gotcha.

# preload (not the global class_name) so the headless tools path
# (gen_art.gd --script) works before a project class scan.
const AppearanceSpec := preload("res://shared/net/appearance.gd")

const FRAME_W := 16
const FRAME_H := 24
const COLS := 10
const ROWS := 3
const DIR_DOWN := 0
const DIR_UP := 1
const DIR_SIDE := 2
const TRANSPARENT := Color(0, 0, 0, 0)
const NEIGHBORS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
# Spiky-hair pixel columns (typed consts: a ternary of raw literals loses the
# array type and fails Array[int] assignment at runtime).
const SPIKE_XS: Array[int] = [5, 7, 9]
const SPIKE_XS_UP: Array[int] = [4, 6, 8, 10]

# --- public: bake a full character sheet --------------------------------------
static func bake_sheet(appearance: int) -> Image:
	var a: int = AppearanceSpec.sanitize(appearance)
	var p := palette_for(a)
	var img: Image = Image.create_empty(FRAME_W * COLS, FRAME_H * ROWS, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for dir in ROWS:
		var oy := dir * FRAME_H
		_frame(img, 0 * FRAME_W, oy, dir, a, p, "idle", 0)
		_frame(img, 1 * FRAME_W, oy, dir, a, p, "idle", 1)
		for i in 4:
			_frame(img, (2 + i) * FRAME_W, oy, dir, a, p, "walk", i)
		for i in 4:
			_frame(img, (6 + i) * FRAME_W, oy, dir, a, p, "attack", i)
	return img

## Palette dict in the same shape ArtBaker's old `_player` used
## (skin/skin_sh/hair/hair_hi/tunic/tunic_hi/trim/boots/blade/blade_hi/outline).
## Built per call (cheap, and Color.html is not a constant expression); index 0 of
## every axis is the original player.png color pair.
static func palette_for(appearance: int) -> Dictionary:
	var a: int = AppearanceSpec.sanitize(appearance)
	var p: Dictionary = {"outline": Color.html("#1a1a22")}
	_apply_skin(p, AppearanceSpec.skin_tone_of(a))
	_apply_hair(p, AppearanceSpec.hair_color_of(a))
	_apply_outfit(p, AppearanceSpec.char_class_of(a))
	return p

static func _apply_skin(p: Dictionary, tone: int) -> void:
	match tone:
		1:  # tan
			p["skin"] = Color.html("#c98e5f")
			p["skin_sh"] = Color.html("#b07348")
		2:  # dark
			p["skin"] = Color.html("#8a5a3a")
			p["skin_sh"] = Color.html("#6e4429")
		3:  # pale
			p["skin"] = Color.html("#f4d5b8")
			p["skin_sh"] = Color.html("#dbb493")
		_:  # default (original)
			p["skin"] = Color.html("#e8b890")
			p["skin_sh"] = Color.html("#d09a72")

static func _apply_hair(p: Dictionary, color: int) -> void:
	match color:
		1:  # black
			p["hair"] = Color.html("#262630")
			p["hair_hi"] = Color.html("#3a3a46")
		2:  # blonde
			p["hair"] = Color.html("#c9a24b")
			p["hair_hi"] = Color.html("#e0bb63")
		3:  # red
			p["hair"] = Color.html("#a03a26")
			p["hair_hi"] = Color.html("#bf5033")
		4:  # white
			p["hair"] = Color.html("#d8d8dc")
			p["hair_hi"] = Color.html("#f0f0f4")
		5:  # blue
			p["hair"] = Color.html("#3a5aa5")
			p["hair_hi"] = Color.html("#4a72c4")
		_:  # brown (original)
			p["hair"] = Color.html("#5a3a22")
			p["hair_hi"] = Color.html("#6e4a2c")

static func _apply_outfit(p: Dictionary, char_class: int) -> void:
	match char_class:
		AppearanceSpec.CLASS_MAGE:  # purple robe; blade = staff wood, blade_hi = gem
			p["tunic"] = Color.html("#6a3a9a")
			p["tunic_hi"] = Color.html("#8352b5")
			p["trim"] = Color.html("#472366")
			p["boots"] = Color.html("#2a2135")
			p["blade"] = Color.html("#8a5c33")
			p["blade_hi"] = Color.html("#6ee0d8")
		AppearanceSpec.CLASS_ARCHER:  # green tunic; blade = bow wood, blade_hi = string
			p["tunic"] = Color.html("#3f7a3a")
			p["tunic_hi"] = Color.html("#529a4a")
			p["trim"] = Color.html("#2a522a")
			p["boots"] = Color.html("#4a3520")
			p["blade"] = Color.html("#7a5230")
			p["blade_hi"] = Color.html("#ece6d2")
		_:  # warrior (original blues + sword)
			p["tunic"] = Color.html("#3a6ea5")
			p["tunic_hi"] = Color.html("#4a82bd")
			p["trim"] = Color.html("#274b73")
			p["boots"] = Color.html("#3a2a1a")
			p["blade"] = Color.html("#d8d8e0")
			p["blade_hi"] = Color.html("#f2f2fa")

# --- public: low-level pixel helpers (shared with ArtBaker) --------------------
## Filled rect in frame-local coords, clamped to the [ox,oy]+frame box.
static func fill(img: Image, ox: int, oy: int, lx: int, ly: int, w: int, h: int, col: Color) -> void:
	for yy in range(ly, ly + h):
		for xx in range(lx, lx + w):
			if xx >= 0 and yy >= 0 and xx < FRAME_W and yy < FRAME_H:
				img.set_pixelv(Vector2i(ox + xx, oy + yy), col)

static func px(img: Image, ox: int, oy: int, lx: int, ly: int, col: Color) -> void:
	if lx >= 0 and ly >= 0 and lx < FRAME_W and ly < FRAME_H:
		img.set_pixelv(Vector2i(ox + lx, oy + ly), col)

## Add a 1px outline to every transparent pixel touching a filled one, kept
## strictly inside the frame box (so it never bleeds into neighbour frames).
static func outline_frame(img: Image, ox: int, oy: int, col: Color) -> void:
	var marks: Array[Vector2i] = []
	for ly in FRAME_H:
		for lx in FRAME_W:
			if img.get_pixel(ox + lx, oy + ly).a > 0.0:
				continue
			var touch := false
			for d in NEIGHBORS:
				var nx := lx + d.x
				var ny := ly + d.y
				if nx >= 0 and ny >= 0 and nx < FRAME_W and ny < FRAME_H:
					if img.get_pixel(ox + nx, oy + ny).a > 0.0:
						touch = true
						break
			if touch:
				marks.append(Vector2i(ox + lx, oy + ly))
	for m in marks:
		img.set_pixelv(m, col)

# --- one frame -----------------------------------------------------------------
static func _frame(img: Image, ox: int, oy: int, dir: int, a: int, p: Dictionary, kind: String, fi: int) -> void:
	_draw_humanoid(img, ox, oy, dir, a, p, kind, fi)
	outline_frame(img, ox, oy, p["outline"])

static func _draw_humanoid(img: Image, ox: int, oy: int, dir: int, a: int, p: Dictionary, kind: String, fi: int) -> void:
	var bob := 0
	var swing := 0
	match kind:
		"idle":
			bob = 1 if fi == 1 else 0
		"walk":
			swing = [0, 1, 0, -1][fi]
			bob = 0 if (fi == 1 or fi == 3) else 1
		"attack":
			bob = 0
	var b := bob  # vertical body offset
	var hair_style: int = AppearanceSpec.hair_style_of(a)

	# Head (hair style aware; style 0 = the original rects verbatim).
	_draw_head(img, ox, oy, dir, hair_style, p, b)

	# Torso + arms.
	if dir == DIR_SIDE:
		fill(img, ox, oy, 6, 8 + b, 5, 7, p["tunic"])
		fill(img, ox, oy, 6, 8 + b, 1, 6, p["tunic_hi"])  # lit left edge
		fill(img, ox, oy, 6, 12 + b, 5, 1, p["trim"])
		fill(img, ox, oy, 8, 8 + b, 2, 5, p["skin"])  # forward arm
	else:
		fill(img, ox, oy, 4, 8 + b, 8, 7, p["tunic"])
		fill(img, ox, oy, 4, 8 + b, 1, 6, p["tunic_hi"])  # lit left edge
		fill(img, ox, oy, 4, 12 + b, 8, 1, p["trim"])
		fill(img, ox, oy, 3, 8 + b, 1, 5, p["skin"])
		fill(img, ox, oy, 12, 8 + b, 1, 5, p["skin"])

	# Long hair spills over the shoulders — drawn after the torso so it reads as
	# lying on top of the tunic (style 1 only; other styles stay in the head zone).
	if hair_style == AppearanceSpec.HAIR_LONG:
		match dir:
			DIR_DOWN:
				fill(img, ox, oy, 4, 8 + b, 1, 2, p["hair"])
				fill(img, ox, oy, 11, 8 + b, 1, 2, p["hair"])
			DIR_UP:
				fill(img, ox, oy, 4, 8 + b, 8, 2, p["hair"])
			DIR_SIDE:
				fill(img, ox, oy, 5, 8 + b, 2, 2, p["hair"])

	# Legs.
	var leg_top := 15 + b
	if dir == DIR_SIDE:
		var front := 1 if swing > 0 else 0
		var back := 1 if swing < 0 else 0
		_leg(img, ox, oy, 6, leg_top + back, p)
		_leg(img, ox, oy, 8, leg_top + front, p)
	else:
		var l := 1 if swing > 0 else 0
		var r := 1 if swing < 0 else 0
		_leg(img, ox, oy, 5, leg_top + l, p)
		_leg(img, ox, oy, 9, leg_top + r, p)

	# Weapon (attack only), per class.
	if kind == "attack":
		match AppearanceSpec.char_class_of(a):
			AppearanceSpec.CLASS_MAGE:
				_draw_staff(img, ox, oy, dir, p, fi >= 2, b)
			AppearanceSpec.CLASS_ARCHER:
				_draw_bow(img, ox, oy, dir, p, fi >= 2, b)
			_:
				_draw_sword(img, ox, oy, dir, p, fi >= 2, b)

# --- head / hair ----------------------------------------------------------------
static func _draw_head(img: Image, ox: int, oy: int, dir: int, style: int, p: Dictionary, b: int) -> void:
	if style == AppearanceSpec.HAIR_BALD:
		_draw_head_bald(img, ox, oy, dir, p, b)
		return
	# Hairy styles share the original head; long/spiky add on top of it.
	match dir:
		DIR_DOWN:
			fill(img, ox, oy, 5, 1 + b, 6, 3, p["hair"])
			fill(img, ox, oy, 5, 1 + b, 6, 1, p["hair_hi"])   # lit top of hair
			fill(img, ox, oy, 4, 4 + b, 8, 4, p["skin"])
			fill(img, ox, oy, 10, 5 + b, 1, 2, p["skin_sh"])  # right-cheek shadow
			var lock_h := 4 if style == AppearanceSpec.HAIR_LONG else 3
			fill(img, ox, oy, 4, 4 + b, 1, lock_h, p["hair"])
			fill(img, ox, oy, 11, 4 + b, 1, lock_h, p["hair"])
			px(img, ox, oy, 6, 6 + b, p["outline"])
			px(img, ox, oy, 9, 6 + b, p["outline"])
		DIR_UP:
			fill(img, ox, oy, 4, 1 + b, 8, 7, p["hair"])
			fill(img, ox, oy, 4, 1 + b, 8, 1, p["hair_hi"])   # lit top of hair
		DIR_SIDE:
			fill(img, ox, oy, 5, 1 + b, 6, 4, p["hair"])
			fill(img, ox, oy, 5, 1 + b, 6, 1, p["hair_hi"])   # lit top of hair
			fill(img, ox, oy, 7, 4 + b, 4, 3, p["skin"])
			if style == AppearanceSpec.HAIR_LONG:
				fill(img, ox, oy, 5, 5 + b, 2, 3, p["hair"])  # back-of-head lock
			px(img, ox, oy, 9, 5 + b, p["outline"])
	if style == AppearanceSpec.HAIR_SPIKY:
		var xs: Array[int] = SPIKE_XS_UP if dir == DIR_UP else SPIKE_XS
		for x in xs:
			px(img, ox, oy, x, 0 + b, p["hair"])

static func _draw_head_bald(img: Image, ox: int, oy: int, dir: int, p: Dictionary, b: int) -> void:
	match dir:
		DIR_DOWN:
			fill(img, ox, oy, 5, 2 + b, 6, 2, p["skin"])       # dome
			fill(img, ox, oy, 10, 2 + b, 1, 2, p["skin_sh"])
			fill(img, ox, oy, 4, 4 + b, 8, 4, p["skin"])
			fill(img, ox, oy, 10, 5 + b, 1, 2, p["skin_sh"])   # right-cheek shadow
			px(img, ox, oy, 6, 6 + b, p["outline"])
			px(img, ox, oy, 9, 6 + b, p["outline"])
		DIR_UP:
			fill(img, ox, oy, 4, 2 + b, 8, 6, p["skin"])
			fill(img, ox, oy, 4, 2 + b, 8, 1, p["skin_sh"])    # shaded crown
		DIR_SIDE:
			fill(img, ox, oy, 5, 2 + b, 6, 3, p["skin"])       # dome
			fill(img, ox, oy, 5, 3 + b, 1, 2, p["skin_sh"])    # back of head
			fill(img, ox, oy, 7, 4 + b, 4, 3, p["skin"])
			px(img, ox, oy, 9, 5 + b, p["outline"])

static func _leg(img: Image, ox: int, oy: int, x: int, top: int, p: Dictionary) -> void:
	fill(img, ox, oy, x, top, 2, 4, p["trim"])
	fill(img, ox, oy, x, top + 4, 2, 2, p["boots"])

# --- weapons (attack frames only; same poses/timings — visual only) --------------
static func _draw_sword(img: Image, ox: int, oy: int, dir: int, p: Dictionary, striking: bool, b: int) -> void:
	var blade: Color = p["blade"]
	var skin: Color = p["skin"]
	match dir:
		DIR_DOWN:
			if striking:
				fill(img, ox, oy, 11, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 11, 12 + b, 2, 9, blade)
			else:
				fill(img, ox, oy, 11, 7 + b, 2, 2, skin)
				fill(img, ox, oy, 12, 1 + b, 2, 6, blade)
		DIR_UP:
			if striking:
				fill(img, ox, oy, 10, 8 + b, 2, 2, skin)
				fill(img, ox, oy, 10, 0, 2, 9, blade)
			else:
				fill(img, ox, oy, 3, 7 + b, 2, 2, skin)
				fill(img, ox, oy, 2, 1 + b, 2, 6, blade)
		DIR_SIDE:
			if striking:
				fill(img, ox, oy, 10, 9 + b, 2, 2, skin)
				fill(img, ox, oy, 11, 9 + b, 4, 2, blade)
			else:
				fill(img, ox, oy, 9, 7 + b, 2, 2, skin)
				fill(img, ox, oy, 10, 1 + b, 2, 6, blade)

## Same hand/pose rects as the sword, but a wood shaft with a 2x2 gem at the tip.
static func _draw_staff(img: Image, ox: int, oy: int, dir: int, p: Dictionary, striking: bool, b: int) -> void:
	var wood: Color = p["blade"]
	var gem: Color = p["blade_hi"]
	var skin: Color = p["skin"]
	match dir:
		DIR_DOWN:
			if striking:
				fill(img, ox, oy, 11, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 11, 12 + b, 2, 9, wood)
				fill(img, ox, oy, 11, 19 + b, 2, 2, gem)
			else:
				fill(img, ox, oy, 11, 7 + b, 2, 2, skin)
				fill(img, ox, oy, 12, 1 + b, 2, 6, wood)
				fill(img, ox, oy, 12, 1 + b, 2, 2, gem)
		DIR_UP:
			if striking:
				fill(img, ox, oy, 10, 8 + b, 2, 2, skin)
				fill(img, ox, oy, 10, 0, 2, 9, wood)
				fill(img, ox, oy, 10, 0, 2, 2, gem)
			else:
				fill(img, ox, oy, 3, 7 + b, 2, 2, skin)
				fill(img, ox, oy, 2, 1 + b, 2, 6, wood)
				fill(img, ox, oy, 2, 1 + b, 2, 2, gem)
		DIR_SIDE:
			if striking:
				fill(img, ox, oy, 10, 9 + b, 2, 2, skin)
				fill(img, ox, oy, 11, 9 + b, 4, 2, wood)
				fill(img, ox, oy, 13, 9 + b, 2, 2, gem)
			else:
				fill(img, ox, oy, 9, 7 + b, 2, 2, skin)
				fill(img, ox, oy, 10, 1 + b, 2, 6, wood)
				fill(img, ox, oy, 10, 1 + b, 2, 2, gem)

## A small vertical D-bow: straight string column + bulged wood column beside it.
static func _draw_bow(img: Image, ox: int, oy: int, dir: int, p: Dictionary, striking: bool, b: int) -> void:
	var skin: Color = p["skin"]
	match dir:
		DIR_DOWN:
			if striking:
				fill(img, ox, oy, 11, 10 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 12, 12 + b, 7, p, 1)
			else:
				fill(img, ox, oy, 11, 7 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 12, 1 + b, 7, p, 1)
		DIR_UP:
			if striking:
				fill(img, ox, oy, 10, 8 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 10, 0, 7, p, 1)
			else:
				fill(img, ox, oy, 3, 7 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 3, 1 + b, 7, p, -1)
		DIR_SIDE:
			if striking:
				fill(img, ox, oy, 10, 9 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 12, 6 + b, 7, p, 1)
			else:
				fill(img, ox, oy, 9, 7 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 10, 1 + b, 7, p, 1)

## String at column x (full height), wood curve one column toward `side`,
## inset one pixel at each end so the tips meet the string.
static func _bow_v(img: Image, ox: int, oy: int, x: int, y: int, h: int, p: Dictionary, side: int) -> void:
	fill(img, ox, oy, x, y, 1, h, p["blade_hi"])
	fill(img, ox, oy, x + side, y + 1, 1, h - 2, p["blade"])
