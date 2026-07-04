class_name ArtBaker extends RefCounted
## Bakes all of the game's placeholder pixel art from code into assets/ as PNGs.
## Run head-less via tools/gen_art.gd — see CLAUDE.md "Running & testing".
## Everything here is plain image math (Image.fill_rect / set_pixel); there is NO
## randomness so re-running produces byte-identical sheets. The look is a chunky,
## outlined, minimalist Game-Boy / Golden-Sun style.
##
## Sheet contracts (must stay in sync with client/char_anim.gd & world/floor_renderer.gd):
##   characters : 160x72, frame 16x24, rows = DOWN/UP/SIDE, cols = idle(0-1) walk(2-5) attack(6-9)
##                (the humanoid/player painter lives in client/char_painter.gd, shared
##                with the runtime character-creator baking; the slime stays here)
##   slash fx   : 160x32, frame 32x32, 5 frames, authored pointing +X
##   terrain    : 48x96,  tile 16x16,  cols = floor/floor_alt/cliff (col 2 is the
##                cliff/rim tile FloorRenderer tiles under islands, NOT a top-down wall),
##                rows = forest/desert/snow/swamp/volcano/savanna (BiomeRegistry order)
##   bridge     : 16x16 single wood-plank tile (tinted per biome at runtime)
##   foliage    : 96x24, cell 16x24, 6 cells = tree x3 / grass / rock x2 (biome-tinted)

const SPRITES_DIR := "res://assets/sprites"
const TILES_DIR := "res://assets/tiles"

# The humanoid painter is shared with the client, which re-bakes recolored /
# restyled sheets at runtime (character creator). preload, not the global
# class_name, so the --script tools path works before a project class scan.
const CharPainterScript := preload("res://client/char_painter.gd")

# --- character sheet geometry ------------------------------------------------
const FRAME_W := 16
const FRAME_H := 24
const COLS := 10
const ROWS := 3
const DIR_DOWN := 0
const DIR_UP := 1
const DIR_SIDE := 2
const TRANSPARENT := Color(0, 0, 0, 0)
const NEIGHBORS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# --- terrain texture detail (typed so for-loops stay non-Variant) ------------
# 4x4 ordered (Bayer) matrix, flattened; used by _dither for a tileable stipple.
const BAYER4: Array[int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
# Fixed grain/tuft positions per floor column, distinct so the renderer's 2x2
# floor/floor_alt tiling reads as varied ground instead of an obvious checker.
const FLOOR_SPECKS: Array[Vector2i] = [Vector2i(3, 4), Vector2i(10, 2), Vector2i(6, 9), Vector2i(13, 12), Vector2i(2, 13), Vector2i(9, 6)]
const ALT_SPECKS: Array[Vector2i] = [Vector2i(5, 3), Vector2i(12, 7), Vector2i(2, 10), Vector2i(8, 13), Vector2i(14, 4), Vector2i(6, 1)]
const FLOOR_TUFTS: Array[Vector2i] = [Vector2i(4, 11), Vector2i(11, 8)]
const ALT_TUFTS: Array[Vector2i] = [Vector2i(7, 5), Vector2i(3, 14)]
const CLIFF_STRATA: Array[int] = [2, 7, 12]
const CLIFF_CRACKS: Array[Vector2i] = [Vector2i(4, 3), Vector2i(11, 9), Vector2i(7, 14)]
const PLANK_SEAMS: Array[int] = [0, 5, 10, 15]
const PLANK_NAILS: Array[Vector2i] = [Vector2i(2, 1), Vector2i(13, 1), Vector2i(2, 11), Vector2i(13, 11)]

# Palettes built at construction (Color.html is not a constant expression).
# The player palette lives in client/char_painter.gd (palette_for), keyed by
# the Appearance code; appearance 0 reproduces the original player.png.
var _monster: Dictionary
var _forest: Dictionary
var _desert: Dictionary
var _snow: Dictionary
var _swamp: Dictionary
var _volcano: Dictionary
var _savanna: Dictionary

func _init() -> void:
	_monster = {
		"body": Color.html("#8a3ca0"), "belly": Color.html("#b25fc8"),
		"eye": Color.html("#ffd84d"), "outline": Color.html("#2a1030"),
		"body_hi": Color.html("#a85fc0"), "body_sh": Color.html("#6a2c80"),
	}
	_forest = {
		"floor": Color.html("#3b6b35"), "floor_alt": Color.html("#446f3a"),
		"shadow": Color.html("#274a23"), "wall_top": Color.html("#6f5a3a"),
		"wall_side": Color.html("#5a4631"),
		"detail": Color.html("#2f5a2a"), "detail2": Color.html("#4a3a24"), "tuft": Color.html("#5f8a45"),
	}
	_desert = {
		"floor": Color.html("#cdb37a"), "floor_alt": Color.html("#d8c089"),
		"shadow": Color.html("#a98f5c"), "wall_top": Color.html("#b08a55"),
		"wall_side": Color.html("#9b7a4a"),
		"detail": Color.html("#b89a63"), "detail2": Color.html("#8a7048"), "tuft": Color.html("#e8d6a0"),
	}
	_snow = {
		"floor": Color.html("#d9e4ec"), "floor_alt": Color.html("#c8d6e0"),
		"shadow": Color.html("#aebfcb"), "wall_top": Color.html("#a7bccb"),
		"wall_side": Color.html("#8fa6b8"),
		"detail": Color.html("#b8ccd8"), "detail2": Color.html("#9fb2c0"), "tuft": Color.html("#f0f6ff"),
	}
	_swamp = {
		"floor": Color.html("#3f5147"), "floor_alt": Color.html("#486055"),
		"shadow": Color.html("#2c3a32"), "wall_top": Color.html("#4d5a40"),
		"wall_side": Color.html("#3a4530"),
		"detail": Color.html("#33443a"), "detail2": Color.html("#3d5240"), "tuft": Color.html("#6a8a4a"),
	}
	_volcano = {
		"floor": Color.html("#4e4650"), "floor_alt": Color.html("#5a5160"),
		"shadow": Color.html("#332b38"), "wall_top": Color.html("#8a3326"),
		"wall_side": Color.html("#5e2418"),
		"detail": Color.html("#3a333f"), "detail2": Color.html("#7a3320"), "tuft": Color.html("#c86a3a"),
	}
	_savanna = {
		"floor": Color.html("#9aa356"), "floor_alt": Color.html("#a7b061"),
		"shadow": Color.html("#76803c"), "wall_top": Color.html("#8a7440"),
		"wall_side": Color.html("#6e5c32"),
		"detail": Color.html("#8a8040"), "detail2": Color.html("#6e5c32"), "tuft": Color.html("#c8c070"),
	}

# --- entry point -------------------------------------------------------------
func bake_all() -> int:
	var failures := 0
	failures += _save(CharPainterScript.bake_sheet(0), "%s/player.png" % SPRITES_DIR)
	failures += _save(_bake_monster(), "%s/monster.png" % SPRITES_DIR)
	failures += _save(_bake_slash(), "%s/fx_slash.png" % SPRITES_DIR)
	failures += _save(_bake_terrain(), "%s/terrain.png" % TILES_DIR)
	failures += _save(_bake_bridge(), "%s/bridge.png" % TILES_DIR)
	failures += _save(_bake_foliage(), "%s/foliage.png" % TILES_DIR)
	return failures

func _save(img: Image, path: String) -> int:
	var err := img.save_png(path)
	if err != OK:
		printerr("[ArtBaker] failed to save %s (err %d)" % [path, err])
		return 1
	print("[ArtBaker] wrote %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	return 0

# --- low-level image helpers -------------------------------------------------
func _new_sheet(w: int, h: int) -> Image:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	return img

## Filled rect in frame-local coords, clamped to the [ox,oy]+frame box.
func _fill(img: Image, ox: int, oy: int, lx: int, ly: int, w: int, h: int, col: Color) -> void:
	CharPainterScript.fill(img, ox, oy, lx, ly, w, h, col)

func _px(img: Image, ox: int, oy: int, lx: int, ly: int, col: Color) -> void:
	CharPainterScript.px(img, ox, oy, lx, ly, col)

## Add a 1px outline to every transparent pixel touching a filled one, kept
## strictly inside the frame box (so it never bleeds into neighbour frames).
func _outline_frame(img: Image, ox: int, oy: int, col: Color) -> void:
	CharPainterScript.outline_frame(img, ox, oy, col)

# --- characters ----------------------------------------------------------------
# The humanoid (player) sheet is baked by CharPainterScript.bake_sheet — see
# bake_all(). Only the slime stays here.
func _bake_monster() -> Image:
	var img := _new_sheet(FRAME_W * COLS, FRAME_H * ROWS)
	for dir in ROWS:
		var oy := dir * FRAME_H
		_monster_frame(img, 0 * FRAME_W, oy, dir, "idle", 0)
		_monster_frame(img, 1 * FRAME_W, oy, dir, "idle", 1)
		for i in 4:
			_monster_frame(img, (2 + i) * FRAME_W, oy, dir, "walk", i)
		for i in 4:
			_monster_frame(img, (6 + i) * FRAME_W, oy, dir, "attack", i)
	return img

func _monster_frame(img: Image, ox: int, oy: int, dir: int, kind: String, fi: int) -> void:
	_draw_slime(img, ox, oy, dir, _monster, kind, fi)
	_outline_frame(img, ox, oy, _monster["outline"])

# --- slime (monster) ---------------------------------------------------------
func _draw_slime(img: Image, ox: int, oy: int, dir: int, p: Dictionary, kind: String, fi: int) -> void:
	var rise := 0      # whole body lifts (hop)
	var squash := 0    # flatten + widen
	var lunge := 0     # shove toward facing on the strike
	match kind:
		"idle":
			squash = 1 if fi == 1 else 0
		"walk":
			rise = [0, 2, 0, 2][fi]
		"attack":
			lunge = 2 if fi >= 2 else 0

	var lx := 0
	var ly := 0
	match dir:
		DIR_SIDE:
			lx = lunge
		DIR_UP:
			ly = -lunge
		DIR_DOWN:
			ly = lunge
	var top := 9 - rise + ly + (1 if squash == 1 else 0)

	# Dome body: stacked rects, widest in the middle.
	_fill(img, ox, oy, 5 + lx, top, 6, 2, p["body"])
	_fill(img, ox, oy, 5 + lx, top, 6, 1, p["body_hi"])   # rim light on the crown
	_fill(img, ox, oy, 4 + lx, top + 2, 8, 4, p["body"])
	_fill(img, ox, oy, 3 + lx - squash, top + 5, 10 + squash * 2, 5 - squash, p["body"])
	_fill(img, ox, oy, 3 + lx - squash, top + 9 - squash, 10 + squash * 2, 1, p["body_sh"])  # grounded shadow
	_fill(img, ox, oy, 6 + lx, top + 4, 4, 4, p["belly"])

	# Eyes by facing.
	match dir:
		DIR_DOWN:
			_px(img, ox, oy, 6 + lx, top + 3, p["eye"])
			_px(img, ox, oy, 9 + lx, top + 3, p["eye"])
		DIR_SIDE:
			_px(img, ox, oy, 9 + lx, top + 3, p["eye"])
			_px(img, ox, oy, 10 + lx, top + 3, p["eye"])
		DIR_UP:
			pass  # back of the blob — no eyes

	# Angry open mouth on the strike.
	if kind == "attack" and fi >= 2 and dir != DIR_UP:
		_fill(img, ox, oy, 7 + lx, top + 7, 2, 2, p["outline"])

# --- slash fx ----------------------------------------------------------------
func _bake_slash() -> Image:
	var fw := 32
	var fh := 32
	var img := Image.create_empty(fw * 5, fh, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	var cx := 6.0   # arc pivots near the attacker (left side of the frame)
	var cy := 16.0
	var half := deg_to_rad(60.0)  # 120-degree cone, matching MeleeSwing.ARC_DEGREES
	for f in 5:
		var ox := f * fw
		var t := float(f) / 4.0
		var radius: float = 12.0 + t * 12.0
		var alpha: float = 1.0 if f < 3 else (0.7 if f == 3 else 0.35)
		var col: Color = Color.html("#ffffff") if f == 0 else (Color.html("#ffe9a8") if f <= 2 else Color.html("#ff8a3c"))
		col.a = alpha
		# Sweep the lit part of the arc; later frames trail further around.
		var a_start: float = -half + lerp(0.0, half * 0.6, t)
		var a_end := half
		var steps := 48
		for i in steps + 1:
			var ang: float = lerp(a_start, a_end, float(i) / float(steps))
			var lead: bool = i >= steps - 2   # bright leading tip of the sweep
			for rr in range(int(radius) - 3, int(radius) + 1):
				var x := int(round(cx + cos(ang) * float(rr)))
				var y := int(round(cy + sin(ang) * float(rr)))
				if x >= 0 and y >= 0 and x < fw and y < fh:
					# Bright white inner core + leading edge; the tinted band trails behind.
					var pc: Color = col
					if rr <= int(radius) - 2 or lead:
						pc = Color(1.0, 1.0, 1.0, alpha)
					img.set_pixelv(Vector2i(ox + x, y), pc)
	return img

# --- terrain atlas -----------------------------------------------------------
func _bake_terrain() -> Image:
	var ts := 16
	var biomes := [_forest, _desert, _snow, _swamp, _volcano, _savanna]
	var img := Image.create_empty(ts * 3, ts * biomes.size(), false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for row in biomes.size():
		var b: Dictionary = biomes[row]
		_floor_tile(img, 0 * ts, row * ts, ts, b, false)
		_floor_tile(img, 1 * ts, row * ts, ts, b, true)
		_cliff_tile(img, 2 * ts, row * ts, ts, b)   # atlas column 2 = cliff/rim, used by FloorRenderer undersides
	return img

## An ordered (Bayer 4x4) stipple: paints `mix` over `base` for the `amount` fraction
## of pixels in a seamless-tiling pattern (repeats every 4 px). No randomness, so
## re-bakes stay byte-identical.
func _dither(img: Image, ox: int, oy: int, ts: int, base: Color, mix: Color, amount: float) -> void:
	for yy in ts:
		for xx in ts:
			var thr: float = (float(BAYER4[(yy % 4) * 4 + (xx % 4)]) + 0.5) / 16.0
			var col: Color = mix if thr < amount else base
			img.set_pixelv(Vector2i(ox + xx, oy + yy), col)

## A textured floor tile: a stipple between the biome floor/floor_alt tones, a few
## fixed grain specks, and detail tufts. `alt` selects the floor_alt column with a
## distinct stipple + stamp set, so the renderer's 2x2 floor/floor_alt tiling reads
## as varied ground rather than an obvious checker.
func _floor_tile(img: Image, ox: int, oy: int, ts: int, b: Dictionary, alt: bool) -> void:
	var base: Color = b["floor_alt"] if alt else b["floor"]
	var mix: Color = b["floor"] if alt else b["floor_alt"]
	_dither(img, ox, oy, ts, base, mix, 0.30)
	var grain: Color = b["shadow"]
	var specks: Array[Vector2i] = ALT_SPECKS if alt else FLOOR_SPECKS
	for s in specks:
		img.set_pixelv(Vector2i(ox + s.x, oy + s.y), grain)
	# Biome detail: a couple of tiny tufts/pebbles with a highlight blade above.
	var tufts: Array[Vector2i] = ALT_TUFTS if alt else FLOOR_TUFTS
	for t in tufts:
		img.set_pixelv(Vector2i(ox + t.x, oy + t.y), b["detail"])
		img.set_pixelv(Vector2i(ox + t.x, oy + t.y - 1), b["tuft"])
		img.set_pixelv(Vector2i(ox + t.x + 1, oy + t.y), b["detail2"])

## A tileable vertical rocky cliff-face tile (terrain atlas column 2): jagged strata
## bands in the biome wall/shadow tones over a dithered rock base. FloorRenderer tiles
## this across the reverse-pyramid island undersides / rims and adds the lit top lip
## itself, so no highlight is baked here.
func _cliff_tile(img: Image, ox: int, oy: int, ts: int, b: Dictionary) -> void:
	var rock: Color = b["wall_side"]
	var rock_dark: Color = b["shadow"]
	var rock_lit: Color = b["wall_top"]
	_dither(img, ox, oy, ts, rock, rock_dark, 0.35)
	for yy in CLIFF_STRATA:
		for xx in ts:
			if (xx + yy) % 4 != 0:            # jagged strata, not ruler-straight
				img.set_pixelv(Vector2i(ox + xx, oy + yy), rock_lit)
	for c in CLIFF_CRACKS:
		img.set_pixelv(Vector2i(ox + c.x, oy + c.y), rock_dark)

## A single 16x16 wood-plank tile for bridges (assets/tiles/bridge.png). Plank seams
## and nail heads are baked in so tiling reproduces planks with no per-plank draws.
## Neutral wood; FloorRenderer tints it per biome via modulate.
func _bake_bridge() -> Image:
	var ts := 16
	var img := Image.create_empty(ts, ts, false, Image.FORMAT_RGBA8)
	var plank := Color.html("#9a6b3f")
	var plank_alt := Color.html("#8a5d35")
	var groove := Color.html("#5e3d22")
	var nail := Color.html("#3a2614")
	_dither(img, 0, 0, ts, plank, plank_alt, 0.25)
	for yy in PLANK_SEAMS:
		for xx in ts:
			img.set_pixelv(Vector2i(xx, yy), groove)
	for p in PLANK_NAILS:
		img.set_pixelv(p, nail)
	return img

# --- foliage (trees / grass / rocks) -----------------------------------------
## assets/tiles/foliage.png: 6 cells of 16x24 (tree x3, grass, rock x2), outlined and
## rooted at the cell bottom. Drawn in natural colours; the Foliage renderer applies a
## subtle per-biome tint via modulate. Deterministic (no rng).
func _bake_foliage() -> Image:
	var cw := FRAME_W   # 16
	var ch := FRAME_H   # 24
	var cells := 6
	var img := Image.create_empty(cw * cells, ch, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	_tree(img, 0 * cw, "round")
	_tree(img, 1 * cw, "tall")
	_tree(img, 2 * cw, "bushy")
	_grass(img, 3 * cw)
	_rock(img, 4 * cw, false)
	_rock(img, 5 * cw, true)
	for c in cells:
		_outline_frame(img, c * cw, 0, Color.html("#1c2418"))
	return img

func _tree(img: Image, ox: int, style: String) -> void:
	var trunk := Color.html("#5a3f26")
	var leaf := Color.html("#4a7a3a")
	var leaf_hi := Color.html("#6aa050")
	var leaf_sh := Color.html("#2f5528")
	_fill(img, ox, 0, 7, 15, 2, 8, trunk)   # trunk, rooted at the bottom
	match style:
		"tall":
			_fill(img, ox, 0, 6, 2, 4, 12, leaf)
			_fill(img, ox, 0, 5, 4, 6, 9, leaf)
			_fill(img, ox, 0, 6, 2, 2, 12, leaf_hi)
			_fill(img, ox, 0, 9, 5, 2, 8, leaf_sh)
		"bushy":
			_fill(img, ox, 0, 2, 6, 12, 8, leaf)
			_fill(img, ox, 0, 4, 3, 8, 4, leaf)
			_fill(img, ox, 0, 3, 4, 3, 7, leaf_hi)
			_fill(img, ox, 0, 10, 8, 4, 5, leaf_sh)
		_:
			_fill(img, ox, 0, 3, 3, 10, 10, leaf)
			_fill(img, ox, 0, 4, 2, 8, 2, leaf)
			_fill(img, ox, 0, 3, 3, 4, 4, leaf_hi)
			_fill(img, ox, 0, 9, 9, 4, 4, leaf_sh)

func _grass(img: Image, ox: int) -> void:
	var blade := Color.html("#5f9a45")
	var blade_hi := Color.html("#7fbf5a")
	_fill(img, ox, 0, 6, 15, 1, 8, blade)
	_fill(img, ox, 0, 8, 13, 1, 10, blade_hi)
	_fill(img, ox, 0, 10, 16, 1, 7, blade)
	_fill(img, ox, 0, 7, 17, 1, 6, blade_hi)
	_fill(img, ox, 0, 9, 15, 1, 8, blade)

func _rock(img: Image, ox: int, big: bool) -> void:
	var stone := Color.html("#8a8a92")
	var stone_hi := Color.html("#a8a8b0")
	var stone_sh := Color.html("#5c5c66")
	if big:
		_fill(img, ox, 0, 3, 14, 10, 8, stone)
		_fill(img, ox, 0, 4, 13, 7, 2, stone)
		_fill(img, ox, 0, 4, 14, 4, 2, stone_hi)
		_fill(img, ox, 0, 9, 18, 4, 3, stone_sh)
	else:
		_fill(img, ox, 0, 5, 17, 6, 5, stone)
		_fill(img, ox, 0, 6, 17, 2, 2, stone_hi)
		_fill(img, ox, 0, 8, 20, 3, 2, stone_sh)
