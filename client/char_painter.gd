class_name CharPainter extends RefCounted
## The single humanoid sprite-sheet painter, parameterized by an Appearance code.
## The client bakes a sheet AT RUNTIME for any (class, hair style, hair color,
## skin tone) combination — a 288x96 image is trivial CPU work — instead of
## pre-baking every combination as a PNG. ArtBaker still calls bake_sheet(0) to
## emit the default assets/sprites/player.png, and Appearance.DEFAULT (0) must
## reproduce that committed sheet byte-identically.
##
## THIS FILE IS THE SHEET-CONTRACT AUTHORITY: tools/art_baker.gd, client/char_anim.gd
## and client/char_sprite_frames.gd all read the consts below instead of duplicating
## them. Sheet: 288x96, frame 24x32, rows = DOWN/UP/SIDE (left = flip_h of SIDE),
## cols = idle(0-1) walk(2-7) attack(8-11).
##
## Pure deterministic image math — no nodes, no randomness. Native constructions
## are explicitly typed (never `:=`) and first happen in normal frames via
## CharSpriteFrames.warm(), per the 4.7 native-.new()-in-RPC-frame gotcha.

# preload (not the global class_name) so the headless tools path
# (gen_art.gd --script) works before a project class scan.
const AppearanceSpec := preload("res://shared/net/appearance.gd")
const PaletteUtilScript := preload("res://client/palette_util.gd")

# --- sheet contract (single source of truth) -----------------------------------
const FRAME_W := 24
const FRAME_H := 32
const COLS := 12
const ROWS := 3
const DIR_DOWN := 0
const DIR_UP := 1
const DIR_SIDE := 2
const IDLE_COLS: Array[int] = [0, 1]
const WALK_COLS: Array[int] = [2, 3, 4, 5, 6, 7]
const ATTACK_COLS: Array[int] = [8, 9, 10, 11]
const IDLE_FPS := 4.0
const WALK_FPS := 10.0
const ATTACK_FPS := 12.0

const TRANSPARENT := Color(0, 0, 0, 0)
const NEIGHBORS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
# 6-frame walk gait: contact / down / down / contact / down / down, legs swinging
# sinusoidally. swing > 0 = left (or back-view right) leg forward.
const WALK_SWING: Array[int] = [0, 2, 2, 0, -2, -2]
const WALK_BOB: Array[int] = [0, 1, 1, 0, 1, 1]
# Spiky-hair pixel columns (typed consts: a ternary of raw literals loses the
# array type and fails Array[int] assignment at runtime).
const SPIKE_XS: Array[int] = [8, 11, 14]
const SPIKE_XS_UP: Array[int] = [7, 10, 13, 16]
const EYE_CATCH := Color(0.95, 0.97, 1.0)
const GROUND_SHADOW := Color(0.05, 0.05, 0.10, 0.28)

# --- public: bake a full character sheet --------------------------------------
static func bake_sheet(appearance: int) -> Image:
	var a: int = AppearanceSpec.sanitize(appearance)
	var p := palette_for(a)
	var img: Image = Image.create_empty(FRAME_W * COLS, FRAME_H * ROWS, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for dir in ROWS:
		var oy := dir * FRAME_H
		for i in IDLE_COLS.size():
			_frame(img, IDLE_COLS[i] * FRAME_W, oy, dir, a, p, "idle", i)
		for i in WALK_COLS.size():
			_frame(img, WALK_COLS[i] * FRAME_W, oy, dir, a, p, "walk", i)
		for i in ATTACK_COLS.size():
			_frame(img, ATTACK_COLS[i] * FRAME_W, oy, dir, a, p, "attack", i)
	return img

## Palette dict, every surface a 3-tone hue-shifted ramp slice (PaletteUtil):
## skin_sh/skin/skin_hi, hair_sh/hair/hair_hi, trim/tunic_sh/tunic/tunic_hi,
## boots/boots_hi, blade_sh/blade/blade_hi, outline. Built per call (cheap;
## Color.html is not a constant expression).
static func palette_for(appearance: int) -> Dictionary:
	var a: int = AppearanceSpec.sanitize(appearance)
	var p: Dictionary = {}
	_apply_skin(p, AppearanceSpec.skin_tone_of(a))
	_apply_hair(p, AppearanceSpec.hair_color_of(a))
	_apply_outfit(p, AppearanceSpec.char_class_of(a))
	return p

static func _apply_skin(p: Dictionary, tone: int) -> void:
	var base: Color
	match tone:
		1:  # tan
			base = Color.html("#cf8f58")
		2:  # dark
			base = Color.html("#915c38")
		3:  # pale
			base = Color.html("#f8dcc0")
		_:  # default
			base = Color.html("#eab088")
	var r: Array[Color] = PaletteUtilScript.ramp(base)
	p["skin_sh"] = r[1]
	p["skin"] = r[2]
	p["skin_hi"] = r[3]

static func _apply_hair(p: Dictionary, color: int) -> void:
	var base: Color
	match color:
		1:  # black
			base = Color.html("#32323e")
		2:  # blonde
			base = Color.html("#e0b452")
		3:  # red
			base = Color.html("#c04a28")
		4:  # white
			base = Color.html("#e0e0e8")
		5:  # blue
			base = Color.html("#4a70c0")
		_:  # brown
			base = Color.html("#7a4e28")
	var r: Array[Color] = PaletteUtilScript.ramp(base)
	p["hair_sh"] = r[1]
	p["hair"] = r[2]
	p["hair_hi"] = r[3]

static func _apply_outfit(p: Dictionary, char_class: int) -> void:
	var tunic_base: Color
	var boots_base: Color
	match char_class:
		AppearanceSpec.CLASS_MAGE:  # purple robe; blade = staff wood, blade_hi = gem
			tunic_base = Color.html("#7a44b8")
			boots_base = Color.html("#2e2440")
			p["blade"] = Color.html("#96642f")
			p["blade_hi"] = Color.html("#58e8dc")
		AppearanceSpec.CLASS_ARCHER:  # green tunic; blade = bow wood, blade_hi = string
			tunic_base = Color.html("#46953f")
			boots_base = Color.html("#56422a")
			p["blade"] = Color.html("#8a5c33")
			p["blade_hi"] = Color.html("#f2ecd8")
		_:  # warrior: blue tunic + steel sword
			tunic_base = Color.html("#3f7ec2")
			boots_base = Color.html("#4a3320")
			p["blade"] = Color.html("#dcdce8")
			p["blade_hi"] = Color.html("#f6f6ff")
	var r: Array[Color] = PaletteUtilScript.ramp(tunic_base)
	p["trim"] = r[0]
	p["tunic_sh"] = r[1]
	p["tunic"] = r[2]
	p["tunic_hi"] = r[3]
	p["boots"] = boots_base
	p["boots_hi"] = PaletteUtilScript.shade(boots_base, 1.0)
	p["blade_sh"] = PaletteUtilScript.shade(p["blade"], -1.0)
	p["outline"] = PaletteUtilScript.outline_for(tunic_base)

# --- public: low-level pixel helpers (shared with ArtBaker) --------------------
## Filled rect in frame-local coords, clamped to the [ox,oy]+frame box.
## fw/fh override the clamp box for non-character cells (foliage etc.).
static func fill(img: Image, ox: int, oy: int, lx: int, ly: int, w: int, h: int, col: Color, fw: int = FRAME_W, fh: int = FRAME_H) -> void:
	for yy in range(ly, ly + h):
		for xx in range(lx, lx + w):
			if xx >= 0 and yy >= 0 and xx < fw and yy < fh:
				img.set_pixelv(Vector2i(ox + xx, oy + yy), col)

static func px(img: Image, ox: int, oy: int, lx: int, ly: int, col: Color, fw: int = FRAME_W, fh: int = FRAME_H) -> void:
	if lx >= 0 and ly >= 0 and lx < fw and ly < fh:
		img.set_pixelv(Vector2i(ox + lx, oy + ly), col)

## Add a 1px outline to every transparent pixel touching a filled one, kept
## strictly inside the frame box (so it never bleeds into neighbour frames).
static func outline_frame(img: Image, ox: int, oy: int, col: Color, fw: int = FRAME_W, fh: int = FRAME_H) -> void:
	var marks: Array[Vector2i] = []
	for ly in fh:
		for lx in fw:
			if img.get_pixel(ox + lx, oy + ly).a > 0.0:
				continue
			var touch := false
			for d in NEIGHBORS:
				var nx := lx + d.x
				var ny := ly + d.y
				if nx >= 0 and ny >= 0 and nx < fw and ny < fh:
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
	_ground_shadow(img, ox, oy)

## Soft contact shadow under the feet (static across the bob so the ground
## reads planted). Painted after the outline pass and only over transparent
## pixels, so it never eats the boots or their outline.
static func _ground_shadow(img: Image, ox: int, oy: int) -> void:
	for xx in range(7, 17):
		_shadow_px(img, ox, oy, xx, 30)
	for xx in range(9, 15):
		_shadow_px(img, ox, oy, xx, 31)

static func _shadow_px(img: Image, ox: int, oy: int, lx: int, ly: int) -> void:
	if img.get_pixel(ox + lx, oy + ly).a == 0.0:
		img.set_pixelv(Vector2i(ox + lx, oy + ly), GROUND_SHADOW)

static func _draw_humanoid(img: Image, ox: int, oy: int, dir: int, a: int, p: Dictionary, kind: String, fi: int) -> void:
	var bob := 0
	var swing := 0
	var striking := false
	match kind:
		"idle":
			bob = 1 if fi == 1 else 0
		"walk":
			swing = WALK_SWING[fi]
			bob = WALK_BOB[fi]
		"attack":
			# 4 frames: wind-back, strike, strike, recover.
			striking = fi == 1 or fi == 2
	var b := bob  # vertical body offset
	var hair_style: int = AppearanceSpec.hair_style_of(a)
	var cls: int = AppearanceSpec.char_class_of(a)

	_draw_head(img, ox, oy, dir, hair_style, p, b)
	_draw_torso(img, ox, oy, dir, cls, p, b, swing)

	# Long hair spills over the shoulders — drawn after the torso so it reads as
	# lying on top of the tunic (style 1 only; other styles stay in the head zone).
	if hair_style == AppearanceSpec.HAIR_LONG:
		match dir:
			DIR_DOWN:
				fill(img, ox, oy, 7, 12 + b, 1, 3, p["hair"])
				fill(img, ox, oy, 16, 12 + b, 1, 3, p["hair"])
			DIR_UP:
				fill(img, ox, oy, 7, 12 + b, 10, 3, p["hair"])
				fill(img, ox, oy, 7, 14 + b, 10, 1, p["hair_sh"])
			DIR_SIDE:
				fill(img, ox, oy, 8, 12 + b, 2, 3, p["hair"])

	_draw_legs(img, ox, oy, dir, cls, p, b, swing)

	# Weapon (attack only), per class.
	if kind == "attack":
		match cls:
			AppearanceSpec.CLASS_MAGE:
				_draw_staff(img, ox, oy, dir, p, striking, b)
			AppearanceSpec.CLASS_ARCHER:
				_draw_bow(img, ox, oy, dir, p, striking, b)
			_:
				_draw_sword(img, ox, oy, dir, p, striking, b)

# --- head / hair ----------------------------------------------------------------
static func _draw_head(img: Image, ox: int, oy: int, dir: int, style: int, p: Dictionary, b: int) -> void:
	if style == AppearanceSpec.HAIR_BALD:
		_draw_head_bald(img, ox, oy, dir, p, b)
		return
	match dir:
		DIR_DOWN:
			# Hair cap.
			fill(img, ox, oy, 8, 2 + b, 8, 4, p["hair"])
			fill(img, ox, oy, 8, 2 + b, 8, 1, p["hair_hi"])
			fill(img, ox, oy, 15, 3 + b, 1, 3, p["hair_sh"])
			# Face.
			fill(img, ox, oy, 7, 6 + b, 10, 6, p["skin"])
			fill(img, ox, oy, 16, 7 + b, 1, 4, p["skin_sh"])   # right-cheek shadow
			fill(img, ox, oy, 9, 11 + b, 6, 1, p["skin_sh"])   # chin shade
			# Side locks framing the face.
			var lock_h := 6 if style == AppearanceSpec.HAIR_LONG else 4
			fill(img, ox, oy, 7, 6 + b, 1, lock_h, p["hair"])
			fill(img, ox, oy, 16, 6 + b, 1, lock_h, p["hair"])
			_face_down(img, ox, oy, p, b)
		DIR_UP:
			fill(img, ox, oy, 7, 2 + b, 10, 10, p["hair"])
			fill(img, ox, oy, 7, 2 + b, 10, 1, p["hair_hi"])
			fill(img, ox, oy, 7, 10 + b, 10, 2, p["hair_sh"])  # nape shade
		DIR_SIDE:
			fill(img, ox, oy, 8, 2 + b, 8, 4, p["hair"])
			fill(img, ox, oy, 8, 2 + b, 8, 1, p["hair_hi"])
			fill(img, ox, oy, 8, 6 + b, 2, 4, p["hair"])       # back of head
			fill(img, ox, oy, 10, 6 + b, 7, 6, p["skin"])
			fill(img, ox, oy, 10, 9 + b, 1, 3, p["skin_sh"])   # jaw shade at the back
			if style == AppearanceSpec.HAIR_LONG:
				fill(img, ox, oy, 8, 6 + b, 2, 6, p["hair"])
			_face_side(img, ox, oy, p, b)
	if style == AppearanceSpec.HAIR_SPIKY:
		var xs: Array[int] = SPIKE_XS_UP if dir == DIR_UP else SPIKE_XS
		for x in xs:
			fill(img, ox, oy, x, 0 + b, 1, 2, p["hair"])

static func _draw_head_bald(img: Image, ox: int, oy: int, dir: int, p: Dictionary, b: int) -> void:
	match dir:
		DIR_DOWN:
			fill(img, ox, oy, 8, 3 + b, 8, 3, p["skin"])        # dome
			fill(img, ox, oy, 8, 3 + b, 8, 1, p["skin_hi"])
			fill(img, ox, oy, 15, 3 + b, 1, 3, p["skin_sh"])
			fill(img, ox, oy, 7, 6 + b, 10, 6, p["skin"])
			fill(img, ox, oy, 16, 7 + b, 1, 4, p["skin_sh"])
			fill(img, ox, oy, 9, 11 + b, 6, 1, p["skin_sh"])
			_face_down(img, ox, oy, p, b, true)
		DIR_UP:
			fill(img, ox, oy, 7, 3 + b, 10, 9, p["skin"])
			fill(img, ox, oy, 7, 3 + b, 10, 1, p["skin_sh"])    # shaded crown
		DIR_SIDE:
			fill(img, ox, oy, 8, 3 + b, 8, 3, p["skin"])        # dome
			fill(img, ox, oy, 8, 3 + b, 8, 1, p["skin_hi"])
			fill(img, ox, oy, 8, 4 + b, 1, 2, p["skin_sh"])     # back of head
			fill(img, ox, oy, 10, 6 + b, 7, 6, p["skin"])
			fill(img, ox, oy, 10, 9 + b, 1, 3, p["skin_sh"])
			_face_side(img, ox, oy, p, b, true)

## Front face: 2x2 eyes with a catchlight, brows, a small mouth.
static func _face_down(img: Image, ox: int, oy: int, p: Dictionary, b: int, bald: bool = false) -> void:
	var brow: Color = p["skin_sh"] if bald else p["hair_sh"]
	fill(img, ox, oy, 9, 7 + b, 2, 1, brow)
	fill(img, ox, oy, 13, 7 + b, 2, 1, brow)
	fill(img, ox, oy, 9, 8 + b, 2, 2, p["outline"])
	fill(img, ox, oy, 13, 8 + b, 2, 2, p["outline"])
	px(img, ox, oy, 10, 8 + b, EYE_CATCH)
	px(img, ox, oy, 14, 8 + b, EYE_CATCH)
	fill(img, ox, oy, 11, 10 + b, 2, 1, p["skin_sh"])

static func _face_side(img: Image, ox: int, oy: int, p: Dictionary, b: int, bald: bool = false) -> void:
	var brow: Color = p["skin_sh"] if bald else p["hair_sh"]
	fill(img, ox, oy, 14, 7 + b, 2, 1, brow)
	fill(img, ox, oy, 14, 8 + b, 2, 2, p["outline"])
	px(img, ox, oy, 15, 8 + b, EYE_CATCH)

# --- torso / arms -----------------------------------------------------------------
static func _draw_torso(img: Image, ox: int, oy: int, dir: int, cls: int, p: Dictionary, b: int, swing: int) -> void:
	var robe := cls == AppearanceSpec.CLASS_MAGE
	var arm_sw := clampi(swing, -1, 1)   # arms counter-swing the legs
	var bottom := 26 if robe else 21     # robe skirts down over the legs
	var h := bottom - 11
	if dir == DIR_SIDE:
		fill(img, ox, oy, 8, 12 + b, 8, h, p["tunic"])
		fill(img, ox, oy, 8, 12 + b, 8, 2, p["tunic_hi"])          # lit shoulders
		fill(img, ox, oy, 8, 14 + b, 1, h - 3, p["tunic_hi"])      # lit back edge
		fill(img, ox, oy, 15, 14 + b, 1, h - 3, p["tunic_sh"])     # shaded front edge
		fill(img, ox, oy, 8, bottom + b, 8, 1, p["tunic_sh"])
		fill(img, ox, oy, 8, 18 + b, 8, 2, p["trim"])              # belt
		if robe:
			fill(img, ox, oy, 8, 25 + b, 8, 2, p["trim"])          # hem
		# Forward arm: sleeve + hand, counter-swinging in the walk.
		var ay := 13 + b - arm_sw
		if robe:
			fill(img, ox, oy, 12, ay, 3, 5, p["tunic_sh"])
			fill(img, ox, oy, 13, ay + 5, 2, 1, p["skin"])
		else:
			fill(img, ox, oy, 12, ay, 3, 3, p["tunic_sh"])
			fill(img, ox, oy, 12, ay + 3, 3, 3, p["skin"])
		if cls == AppearanceSpec.CLASS_WARRIOR:
			fill(img, ox, oy, 12, 12 + b, 4, 2, p["blade"])        # front pauldron
	else:
		fill(img, ox, oy, 6, 12 + b, 12, h, p["tunic"])
		fill(img, ox, oy, 6, 12 + b, 12, 2, p["tunic_hi"])         # lit chest
		fill(img, ox, oy, 6, 14 + b, 1, h - 3, p["tunic_hi"])      # lit left edge
		fill(img, ox, oy, 17, 14 + b, 1, h - 3, p["tunic_sh"])     # shaded right edge
		fill(img, ox, oy, 6, bottom + b, 12, 1, p["tunic_sh"])
		fill(img, ox, oy, 6, 18 + b, 12, 2, p["trim"])             # belt
		if dir == DIR_DOWN:
			fill(img, ox, oy, 11, 18 + b, 2, 2, p["blade_hi"])     # buckle
		if robe:
			fill(img, ox, oy, 6, 25 + b, 12, 2, p["trim"])         # hem
		# Arms (sleeve + skin), counter-swinging.
		var ly := 12 + b + arm_sw
		var ry := 12 + b - arm_sw
		if robe:
			fill(img, ox, oy, 4, ly, 2, 7, p["tunic_sh"])
			fill(img, ox, oy, 18, ry, 2, 7, p["tunic_sh"])
		else:
			fill(img, ox, oy, 4, ly, 2, 3, p["tunic_sh"])
			fill(img, ox, oy, 4, ly + 3, 2, 4, p["skin"])
			fill(img, ox, oy, 18, ry, 2, 3, p["tunic_sh"])
			fill(img, ox, oy, 18, ry + 3, 2, 4, p["skin"])
		if cls == AppearanceSpec.CLASS_WARRIOR:
			fill(img, ox, oy, 4, 12 + b, 2, 2, p["blade"])         # pauldrons
			fill(img, ox, oy, 18, 12 + b, 2, 2, p["blade"])
		elif cls == AppearanceSpec.CLASS_ARCHER:
			if dir == DIR_DOWN:
				for i in 8:                                        # chest strap
					px(img, ox, oy, 7 + i, 13 + i, p["trim"])
			else:
				fill(img, ox, oy, 13, 12 + b, 3, 7, p["boots"])    # quiver on the back
				fill(img, ox, oy, 13, 12 + b, 3, 1, p["blade_hi"]) # arrow fletching

# --- legs -----------------------------------------------------------------------
static func _draw_legs(img: Image, ox: int, oy: int, dir: int, cls: int, p: Dictionary, b: int, swing: int) -> void:
	if cls == AppearanceSpec.CLASS_MAGE:
		# Robe covers the legs; only the boots peek out, stepping in the walk.
		var l := 1 if swing > 0 else 0
		var r := 1 if swing < 0 else 0
		if dir == DIR_SIDE:
			_boot(img, ox, oy, 9, 27 + b + r, p)
			_boot(img, ox, oy, 12, 27 + b + l, p)
		else:
			_boot(img, ox, oy, 8, 27 + b + l, p)
			_boot(img, ox, oy, 13, 27 + b + r, p)
		return
	var leg_top := 22 + b
	if dir == DIR_SIDE:
		var front := 1 if swing > 0 else 0
		var back := 1 if swing < 0 else 0
		_leg(img, ox, oy, 9, leg_top + back, p)
		_leg(img, ox, oy, 12, leg_top + front, p)
	else:
		var l := 1 if swing > 0 else 0
		var r := 1 if swing < 0 else 0
		_leg(img, ox, oy, 8, leg_top + l, p)
		_leg(img, ox, oy, 13, leg_top + r, p)

static func _leg(img: Image, ox: int, oy: int, x: int, top: int, p: Dictionary) -> void:
	fill(img, ox, oy, x, top, 3, 5, p["trim"])
	_boot(img, ox, oy, x, top + 5, p)

static func _boot(img: Image, ox: int, oy: int, x: int, top: int, p: Dictionary) -> void:
	fill(img, ox, oy, x, top, 3, 3, p["boots"])
	fill(img, ox, oy, x, top, 3, 1, p["boots_hi"])

# --- weapons (attack frames only; poses/timings are visual only) ------------------
static func _draw_sword(img: Image, ox: int, oy: int, dir: int, p: Dictionary, striking: bool, b: int) -> void:
	var blade: Color = p["blade"]
	var blade_hi: Color = p["blade_hi"]
	var skin: Color = p["skin"]
	match dir:
		DIR_DOWN:
			if striking:
				fill(img, ox, oy, 16, 15 + b, 2, 2, skin)
				fill(img, ox, oy, 15, 17 + b, 4, 1, p["trim"])     # crossguard
				fill(img, ox, oy, 16, 18 + b, 2, 11, blade)
				fill(img, ox, oy, 16, 18 + b, 1, 11, blade_hi)
			else:
				fill(img, ox, oy, 16, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 18, 2 + b, 2, 8, blade)
				fill(img, ox, oy, 18, 2 + b, 1, 8, blade_hi)
		DIR_UP:
			if striking:
				fill(img, ox, oy, 15, 12 + b, 2, 2, skin)
				fill(img, ox, oy, 15, 0, 2, 12, blade)
				fill(img, ox, oy, 15, 0, 1, 12, blade_hi)
			else:
				fill(img, ox, oy, 4, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 3, 2 + b, 2, 8, blade)
				fill(img, ox, oy, 3, 2 + b, 1, 8, blade_hi)
		DIR_SIDE:
			if striking:
				fill(img, ox, oy, 15, 13 + b, 2, 2, skin)
				fill(img, ox, oy, 17, 13 + b, 6, 2, blade)
				fill(img, ox, oy, 17, 13 + b, 6, 1, blade_hi)
				px(img, ox, oy, 23, 13 + b, blade_hi)
			else:
				fill(img, ox, oy, 14, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 15, 2 + b, 2, 8, blade)
				fill(img, ox, oy, 15, 2 + b, 1, 8, blade_hi)

## Same hand/pose rects as the sword, but a wood shaft with a glowing gem tip.
static func _draw_staff(img: Image, ox: int, oy: int, dir: int, p: Dictionary, striking: bool, b: int) -> void:
	var wood: Color = p["blade"]
	var gem: Color = p["blade_hi"]
	var skin: Color = p["skin"]
	match dir:
		DIR_DOWN:
			if striking:
				fill(img, ox, oy, 16, 15 + b, 2, 2, skin)
				fill(img, ox, oy, 16, 17 + b, 2, 12, wood)
				fill(img, ox, oy, 16, 26 + b, 2, 3, gem)
				px(img, ox, oy, 17, 27 + b, EYE_CATCH)
			else:
				fill(img, ox, oy, 16, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 18, 2 + b, 2, 8, wood)
				fill(img, ox, oy, 18, 2 + b, 2, 3, gem)
		DIR_UP:
			if striking:
				fill(img, ox, oy, 15, 12 + b, 2, 2, skin)
				fill(img, ox, oy, 15, 0, 2, 12, wood)
				fill(img, ox, oy, 15, 0, 2, 3, gem)
			else:
				fill(img, ox, oy, 4, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 3, 2 + b, 2, 8, wood)
				fill(img, ox, oy, 3, 2 + b, 2, 3, gem)
		DIR_SIDE:
			if striking:
				fill(img, ox, oy, 15, 13 + b, 2, 2, skin)
				fill(img, ox, oy, 17, 13 + b, 6, 2, wood)
				fill(img, ox, oy, 21, 13 + b, 2, 2, gem)
				px(img, ox, oy, 22, 13 + b, EYE_CATCH)
			else:
				fill(img, ox, oy, 14, 10 + b, 2, 2, skin)
				fill(img, ox, oy, 15, 2 + b, 2, 8, wood)
				fill(img, ox, oy, 15, 2 + b, 2, 3, gem)

## A vertical D-bow: straight string column + bulged wood column beside it.
static func _draw_bow(img: Image, ox: int, oy: int, dir: int, p: Dictionary, striking: bool, b: int) -> void:
	var skin: Color = p["skin"]
	match dir:
		DIR_DOWN:
			if striking:
				fill(img, ox, oy, 16, 15 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 17, 17 + b, 10, p, 1)
			else:
				fill(img, ox, oy, 16, 10 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 18, 2 + b, 10, p, 1)
		DIR_UP:
			if striking:
				fill(img, ox, oy, 15, 12 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 15, 0, 10, p, 1)
			else:
				fill(img, ox, oy, 4, 10 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 3, 2 + b, 10, p, -1)
		DIR_SIDE:
			if striking:
				fill(img, ox, oy, 15, 13 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 18, 8 + b, 11, p, 1)
			else:
				fill(img, ox, oy, 14, 10 + b, 2, 2, skin)
				_bow_v(img, ox, oy, 15, 2 + b, 10, p, 1)

## String at column x (full height), wood curve one column toward `side`,
## inset one pixel at each end so the tips meet the string.
static func _bow_v(img: Image, ox: int, oy: int, x: int, y: int, h: int, p: Dictionary, side: int) -> void:
	fill(img, ox, oy, x, y, 1, h, p["blade_hi"])
	fill(img, ox, oy, x + side, y + 1, 1, h - 2, p["blade"])
	fill(img, ox, oy, x + side * 2, y + 3, 1, h - 6, p["blade"])
