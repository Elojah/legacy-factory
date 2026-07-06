class_name ArtBaker extends RefCounted
## Bakes all of the game's placeholder pixel art from code into assets/ as PNGs.
## Run head-less via tools/gen_art.gd — see CLAUDE.md "Running & testing".
## Everything here is plain image math (Image.fill_rect / set_pixel); there is NO
## randomness so re-running produces byte-identical sheets. The look is a chunky,
## outlined, minimalist Game-Boy / Golden-Sun style.
##
## Sheet contracts (character geometry is OWNED by client/char_painter.gd — the
## consts below alias it; keep world/floor_renderer.gd in sync for terrain):
##   characters : 288x96, frame 24x32, rows = DOWN/UP/SIDE, cols = idle(0-1)
##                walk(2-7) attack(8-11) — CharPainter.IDLE/WALK/ATTACK_COLS
##                (the humanoid/player painter lives in client/char_painter.gd, shared
##                with the runtime character-creator baking; the slime stays here)
##   slash fx   : 288x48, frame 48x48, 6 frames, authored pointing +X; plus the
##                fx_* strips (impact/dash/heal/ring/summon/charge/bolt/glow/
##                hazard) — frame sizes/counts live in EffectSpawner's registry
##   terrain    : 96x96,  tile 16x16,  cols = floor/floor_alt/floor_var2/floor_var3/
##                cliff/edge-fringe (col 4 is the cliff/rim tile FloorRenderer tiles
##                under islands, NOT a top-down wall; col 5 is the grass-overhang
##                fringe strip along island bottom edges),
##                rows = forest/desert/snow/swamp/volcano/savanna (BiomeRegistry order)
##   bridge     : 16x16 single wood-plank tile (tinted per biome at runtime)
##   foliage    : 96x48, cell 16x24, row 0 = tree x3 / grass / rock x2,
##                row 1 = flower x2 / pebbles / crack / stump / bush (ground decals);
##                all biome-tinted at runtime

const SPRITES_DIR := "res://assets/sprites"
const TILES_DIR := "res://assets/tiles"
const FONTS_DIR := "res://assets/fonts"

# The humanoid painter is shared with the client, which re-bakes recolored /
# restyled sheets at runtime (character creator). preload, not the global
# class_name, so the --script tools path works before a project class scan.
const CharPainterScript := preload("res://client/char_painter.gd")
const PaletteUtilScript := preload("res://client/palette_util.gd")

# --- character sheet geometry (aliased from the CharPainter contract) ----------
const FRAME_W := CharPainterScript.FRAME_W
const FRAME_H := CharPainterScript.FRAME_H
const COLS := CharPainterScript.COLS
const ROWS := CharPainterScript.ROWS
const DIR_DOWN := 0
const DIR_UP := 1
const DIR_SIDE := 2
const TRANSPARENT := Color(0, 0, 0, 0)
const NEIGHBORS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
# Foliage keeps its own smaller cell (world props, not characters).
const FOLIAGE_CELL_W := 16
const FOLIAGE_CELL_H := 24

# --- terrain texture detail (typed so for-loops stay non-Variant) ------------
# 4x4 ordered (Bayer) matrix, flattened; used by _dither for a tileable stipple.
const BAYER4: Array[int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
# Fixed grain/tuft positions per floor column, distinct so the renderer's 2x2
# floor/floor_alt tiling reads as varied ground instead of an obvious checker.
const FLOOR_SPECKS: Array[Vector2i] = [Vector2i(3, 4), Vector2i(10, 2), Vector2i(6, 9), Vector2i(13, 12), Vector2i(2, 13), Vector2i(9, 6)]
const ALT_SPECKS: Array[Vector2i] = [Vector2i(5, 3), Vector2i(12, 7), Vector2i(2, 10), Vector2i(8, 13), Vector2i(14, 4), Vector2i(6, 1)]
const FLOOR_TUFTS: Array[Vector2i] = [Vector2i(4, 11), Vector2i(11, 8)]
const ALT_TUFTS: Array[Vector2i] = [Vector2i(7, 5), Vector2i(3, 14)]
# floor_var2: lusher — extra tufts get flower/highlight accents.
const VAR2_SPECKS: Array[Vector2i] = [Vector2i(2, 4), Vector2i(11, 2), Vector2i(7, 8), Vector2i(14, 11), Vector2i(4, 14)]
const VAR2_TUFTS: Array[Vector2i] = [Vector2i(3, 5), Vector2i(9, 3), Vector2i(12, 10), Vector2i(5, 12)]
# floor_var3: bare/cracked — a zigzag fissure and dry specks, no growth.
const VAR3_SPECKS: Array[Vector2i] = [Vector2i(12, 3), Vector2i(2, 8), Vector2i(13, 13), Vector2i(6, 11)]
const VAR3_CRACK: Array[Vector2i] = [
	Vector2i(3, 3), Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 5), Vector2i(7, 6),
	Vector2i(7, 7), Vector2i(8, 8), Vector2i(9, 8), Vector2i(10, 9), Vector2i(11, 10),
]
const CLIFF_STRATA: Array[int] = [2, 7, 12]
const CLIFF_CRACKS: Array[Vector2i] = [Vector2i(4, 3), Vector2i(11, 9), Vector2i(7, 14)]
# Grass-overhang fringe: per-column hang length (16 entries, tiles seamlessly).
const FRINGE_LEN: Array[int] = [3, 5, 2, 4, 6, 3, 2, 5, 3, 4, 2, 6, 4, 3, 5, 2]
const PLANK_SEAMS: Array[int] = [0, 5, 10, 15]
const PLANK_NAILS: Array[Vector2i] = [Vector2i(2, 1), Vector2i(13, 1), Vector2i(2, 11), Vector2i(13, 11)]

# Palettes built at construction (Color.html is not a constant expression).
# The player palette lives in client/char_painter.gd (palette_for), keyed by
# the Appearance code; appearance 0 reproduces the original player.png.
var _monster: Dictionary
var _wisp: Dictionary
var _beetle: Dictionary
var _magma: Dictionary
var _frost: Dictionary
var _horror: Dictionary
var _forest: Dictionary
var _desert: Dictionary
var _snow: Dictionary
var _swamp: Dictionary
var _volcano: Dictionary
var _savanna: Dictionary

func _init() -> void:
	var slime_base: Color = Color.html("#9a4cb4")
	var slime_ramp: Array[Color] = PaletteUtilScript.ramp(slime_base)
	_monster = {
		"body_sh": slime_ramp[1], "body": slime_ramp[2], "body_hi": slime_ramp[3],
		"belly": slime_ramp[4], "eye": Color.html("#ffd84d"),
		"outline": PaletteUtilScript.outline_for(slime_base),
	}
	var wisp_base: Color = Color.html("#5aa8e0")
	var wisp_ramp: Array[Color] = PaletteUtilScript.ramp(wisp_base)
	_wisp = {
		"body_sh": wisp_ramp[1], "body": wisp_ramp[2], "body_hi": wisp_ramp[3],
		"core": Color.html("#eafaff"), "eye": Color.html("#183048"),
		"outline": PaletteUtilScript.outline_for(wisp_base),
	}
	var beetle_base: Color = Color.html("#96622e")
	var beetle_ramp: Array[Color] = PaletteUtilScript.ramp(beetle_base)
	_beetle = {
		"body_sh": beetle_ramp[1], "body": beetle_ramp[2], "body_hi": beetle_ramp[3],
		"belly": beetle_ramp[0], "eye": Color.html("#ffd84d"),
		"horn": Color.html("#3c2a16"),
		"outline": PaletteUtilScript.outline_for(beetle_base),
	}
	# Boss kit palettes (BossDefs.KIT_* order — magma / frost / swamp).
	var magma_rock: Color = Color.html("#7a544a")
	var magma_ramp: Array[Color] = PaletteUtilScript.ramp(magma_rock)
	_magma = {
		# Full-ramp extremes (+-2 steps): a 64px hulk needs bolder value contrast
		# than the 24px sprites.
		"rock_sh": magma_ramp[0], "rock": magma_ramp[2], "rock_hi": magma_ramp[4],
		"lava": Color.html("#ff7a30"), "lava_hi": Color.html("#ffd040"),
		"outline": PaletteUtilScript.outline_for(magma_rock),
	}
	var frost_ice: Color = Color.html("#6ec0e8")
	var frost_ramp: Array[Color] = PaletteUtilScript.ramp(frost_ice)
	_frost = {
		"ice_sh": frost_ramp[1], "ice": frost_ramp[2], "ice_hi": frost_ramp[3],
		"crystal": Color.html("#f0faff"), "deep": Color.html("#2a4a8a"),
		"eye": Color.html("#12203a"), "maw": Color.html("#12203a"),
		"outline": PaletteUtilScript.outline_for(frost_ice),
	}
	var horror_moss: Color = Color.html("#4c8a48")
	var horror_ramp: Array[Color] = PaletteUtilScript.ramp(horror_moss)
	_horror = {
		"moss_sh": horror_ramp[1], "moss": horror_ramp[2], "moss_hi": horror_ramp[3],
		"vine": Color.html("#2f5528"), "vine_hi": Color.html("#6aa050"),
		"eye": Color.html("#ffd84d"), "maw": Color.html("#1a2414"),
		"outline": PaletteUtilScript.outline_for(horror_moss),
	}
	# Biome palettes derive from ONE saturated base via PaletteUtil ramps; a few
	# hand overrides keep signature accents (volcano's red rock + lava tufts).
	# Grassy biomes get earth-brown cliff overrides — soil under turf, not green rock.
	_forest = _biome_palette(Color.html("#4c9040"), {
		"wall_top": Color.html("#8a6a42"), "wall_side": Color.html("#6b4e30"),
	})
	_desert = _biome_palette(Color.html("#e2c47e"))
	_snow = _biome_palette(Color.html("#dfeaf6"))
	_swamp = _biome_palette(Color.html("#527a5c"), {
		"wall_top": Color.html("#5d5a3a"), "wall_side": Color.html("#45412a"),
	})
	_volcano = _biome_palette(Color.html("#6b4854"), {
		"wall_top": Color.html("#a03a26"), "wall_side": Color.html("#6e2418"),
		"tuft": Color.html("#ff7a30"), "detail2": Color.html("#7a3320"),
	})
	_savanna = _biome_palette(Color.html("#bcb45e"), {
		"wall_top": Color.html("#94743e"), "wall_side": Color.html("#6e5630"),
	})

## Derive the 8-key biome tile palette from a single base color: dither pairs sit
## close in value but drift in hue (richer, less muddy), walls come from a darker
## rock ramp of the same hue family.
func _biome_palette(base: Color, overrides: Dictionary = {}) -> Dictionary:
	var rock: Color = PaletteUtilScript.shade(base, -1.5)
	var d: Dictionary = {
		"floor": base,
		"floor_alt": PaletteUtilScript.shade(base, 0.6),
		"shadow": PaletteUtilScript.shade(base, -1.2),
		"detail": PaletteUtilScript.shade(base, -0.6),
		"detail2": PaletteUtilScript.shade(base, -1.8),
		"tuft": PaletteUtilScript.shade(base, 1.6),
		"wall_top": PaletteUtilScript.shade(rock, 1.0),
		"wall_side": rock,
	}
	for k in overrides:
		d[k] = overrides[k]
	return d

# --- entry point -------------------------------------------------------------
func bake_all() -> int:
	var failures := 0
	failures += _save(CharPainterScript.bake_sheet(0), "%s/player.png" % SPRITES_DIR)
	failures += _save(_bake_species(0), "%s/monster_slime.png" % SPRITES_DIR)
	failures += _save(_bake_species(1), "%s/monster_beetle.png" % SPRITES_DIR)
	failures += _save(_bake_species(2), "%s/monster_wisp.png" % SPRITES_DIR)
	failures += _save(_bake_boss(0), "%s/boss_magma.png" % SPRITES_DIR)
	failures += _save(_bake_boss(1), "%s/boss_frost.png" % SPRITES_DIR)
	failures += _save(_bake_boss(2), "%s/boss_swamp.png" % SPRITES_DIR)
	failures += _save(_bake_slash(), "%s/fx_slash.png" % SPRITES_DIR)
	failures += _save(_bake_impact(), "%s/fx_impact.png" % SPRITES_DIR)
	failures += _save(_bake_dash(), "%s/fx_dash.png" % SPRITES_DIR)
	failures += _save(_bake_heal(), "%s/fx_heal.png" % SPRITES_DIR)
	failures += _save(_bake_ring(), "%s/fx_ring.png" % SPRITES_DIR)
	failures += _save(_bake_summon(), "%s/fx_summon.png" % SPRITES_DIR)
	failures += _save(_bake_charge(), "%s/fx_charge.png" % SPRITES_DIR)
	failures += _save(_bake_bolt(), "%s/fx_bolt.png" % SPRITES_DIR)
	failures += _save(_bake_glow(), "%s/fx_glow.png" % SPRITES_DIR)
	failures += _save(_bake_hazard_fx(), "%s/fx_hazard.png" % SPRITES_DIR)
	failures += _save(_bake_icons(), "%s/icons_skills.png" % SPRITES_DIR)
	failures += _save(_bake_terrain(), "%s/terrain.png" % TILES_DIR)
	failures += _save(_bake_bridge(), "%s/bridge.png" % TILES_DIR)
	failures += _save(_bake_foliage(), "%s/foliage.png" % TILES_DIR)
	var dir := DirAccess.open("res://")
	if dir != null:
		dir.make_dir_recursive("assets/fonts")
	failures += _save(_bake_font(), "%s/pixel.png" % FONTS_DIR)
	failures += _write_fnt("%s/pixel.fnt" % FONTS_DIR)
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
func _fill(img: Image, ox: int, oy: int, lx: int, ly: int, w: int, h: int, col: Color, fw: int = FRAME_W, fh: int = FRAME_H) -> void:
	CharPainterScript.fill(img, ox, oy, lx, ly, w, h, col, fw, fh)

func _px(img: Image, ox: int, oy: int, lx: int, ly: int, col: Color, fw: int = FRAME_W, fh: int = FRAME_H) -> void:
	CharPainterScript.px(img, ox, oy, lx, ly, col, fw, fh)

## Add a 1px outline to every transparent pixel touching a filled one, kept
## strictly inside the frame box (so it never bleeds into neighbour frames).
func _outline_frame(img: Image, ox: int, oy: int, col: Color, fw: int = FRAME_W, fh: int = FRAME_H) -> void:
	CharPainterScript.outline_frame(img, ox, oy, col, fw, fh)

# --- monster species -------------------------------------------------------------
# The humanoid (player) sheet is baked by CharPainterScript.bake_sheet — see
# bake_all(). Monsters come in 3 species sheets (same layout as the humanoid):
# 0 = slime (forest/swamp), 1 = beetle (desert/savanna), 2 = wisp (snow/volcano);
# the species pick is client-side cosmetic (client/monster_skins.gd).
func _bake_species(species: int) -> Image:
	var img := _new_sheet(FRAME_W * COLS, FRAME_H * ROWS)
	var idle_cols: Array[int] = CharPainterScript.IDLE_COLS
	var walk_cols: Array[int] = CharPainterScript.WALK_COLS
	var attack_cols: Array[int] = CharPainterScript.ATTACK_COLS
	for dir in ROWS:
		var oy := dir * FRAME_H
		for i in idle_cols.size():
			_species_frame(img, idle_cols[i] * FRAME_W, oy, dir, species, "idle", i)
		for i in walk_cols.size():
			_species_frame(img, walk_cols[i] * FRAME_W, oy, dir, species, "walk", i)
		for i in attack_cols.size():
			_species_frame(img, attack_cols[i] * FRAME_W, oy, dir, species, "attack", i)
	return img

func _species_frame(img: Image, ox: int, oy: int, dir: int, species: int, kind: String, fi: int) -> void:
	match species:
		1:
			_draw_beetle(img, ox, oy, dir, _beetle, kind, fi)
			_outline_frame(img, ox, oy, _beetle["outline"])
			CharPainterScript._ground_shadow(img, ox, oy)
		2:
			_draw_wisp(img, ox, oy, dir, _wisp, kind, fi)
			_outline_frame(img, ox, oy, _wisp["outline"])
			_wisp_shadow(img, ox, oy)
		_:
			_draw_slime(img, ox, oy, dir, _monster, kind, fi)
			_outline_frame(img, ox, oy, _monster["outline"])
			CharPainterScript._ground_shadow(img, ox, oy)

## Floating wisp: a smaller, higher shadow (it hovers).
func _wisp_shadow(img: Image, ox: int, oy: int) -> void:
	for xx in range(9, 15):
		CharPainterScript._shadow_px(img, ox, oy, xx, 30)

# --- slime (monster) ---------------------------------------------------------
# 6-frame walk hop and 4-frame attack (windup pull-back / strike / strike / recover).
const SLIME_WALK_RISE: Array[int] = [0, 2, 4, 4, 2, 0]
const SLIME_ATTACK_LUNGE: Array[int] = [-1, 3, 3, 1]

func _draw_slime(img: Image, ox: int, oy: int, dir: int, p: Dictionary, kind: String, fi: int) -> void:
	var rise := 0      # whole body lifts (hop)
	var squash := 0    # flatten + widen
	var lunge := 0     # shove toward facing on the strike
	var biting := false
	match kind:
		"idle":
			squash = 1 if fi == 1 else 0
		"walk":
			rise = SLIME_WALK_RISE[fi]
			squash = 1 if fi == 0 else 0
		"attack":
			lunge = SLIME_ATTACK_LUNGE[fi]
			biting = fi == 1 or fi == 2

	var lx := 0
	var ly := 0
	match dir:
		DIR_SIDE:
			lx = lunge
		DIR_UP:
			ly = -lunge
		DIR_DOWN:
			ly = lunge
	var top := 17 - rise + ly + squash

	# Dome body: stacked rects, widest at the base.
	_fill(img, ox, oy, 8 + lx, top, 8, 2, p["body"])
	_fill(img, ox, oy, 8 + lx, top, 8, 1, p["body_hi"])   # rim light on the crown
	_fill(img, ox, oy, 6 + lx, top + 2, 12, 5, p["body"])
	_fill(img, ox, oy, 6 + lx, top + 2, 1, 5, p["body_hi"])  # lit left flank
	_fill(img, ox, oy, 17 + lx, top + 3, 1, 4, p["body_sh"]) # shaded right flank
	_fill(img, ox, oy, 4 + lx - squash, top + 7, 16 + squash * 2, 5 - squash, p["body"])
	_fill(img, ox, oy, 4 + lx - squash, top + 11 - squash, 16 + squash * 2, 1, p["body_sh"])  # grounded shadow
	if dir != DIR_UP:  # belly patch is front-side only
		_fill(img, ox, oy, 9 + lx, top + 5, 6, 5, p["belly"])
	# Gel glints.
	_px(img, ox, oy, 10 + lx, top + 1, Color(1.0, 1.0, 1.0, 0.85))
	_px(img, ox, oy, 7 + lx, top + 3, Color(1.0, 1.0, 1.0, 0.5))

	# Eyes by facing: 2x2 with a dark pupil.
	match dir:
		DIR_DOWN:
			_slime_eye(img, ox, oy, 9 + lx, top + 4, p)
			_slime_eye(img, ox, oy, 13 + lx, top + 4, p)
		DIR_SIDE:
			_slime_eye(img, ox, oy, 13 + lx, top + 4, p)
			_slime_eye(img, ox, oy, 16 + lx, top + 4, p)
		DIR_UP:
			pass  # back of the blob — no eyes

	# Angry open mouth on the strike.
	if biting and dir != DIR_UP:
		_fill(img, ox, oy, 11 + lx, top + 8, 2, 2, p["outline"])

func _slime_eye(img: Image, ox: int, oy: int, x: int, y: int, p: Dictionary) -> void:
	_fill(img, ox, oy, x, y, 2, 2, p["eye"])
	_px(img, ox, oy, x + 1, y + 1, p["outline"])

# --- wisp (floating spirit flame; snow/volcano) --------------------------------
const WISP_FLOAT: Array[int] = [0, 1, 2, 2, 1, 0]   # 6-frame hover drift

func _draw_wisp(img: Image, ox: int, oy: int, dir: int, p: Dictionary, kind: String, fi: int) -> void:
	var lift := 0
	var flare := 0
	match kind:
		"idle":
			lift = 1 if fi == 1 else 0
		"walk":
			lift = WISP_FLOAT[fi]
		"attack":
			flare = 2 if (fi == 1 or fi == 2) else 0
			lift = 1
	var top := 8 - lift   # hovers well above the ground shadow
	var fl := flare

	# Outer flame body (widens when flaring).
	_fill(img, ox, oy, 9 - fl, top + 2, 6 + fl * 2, 10, p["body"])
	_fill(img, ox, oy, 10 - fl, top, 4 + fl * 2, 2, p["body"])       # crown lick
	_fill(img, ox, oy, 8 - fl, top + 4, 8 + fl * 2, 6, p["body"])
	_fill(img, ox, oy, 9 - fl, top + 2, 1, 8, p["body_hi"])          # lit left edge
	_fill(img, ox, oy, 14 + fl, top + 4, 1, 6, p["body_sh"])         # shaded right
	# Bright core.
	_fill(img, ox, oy, 10, top + 4, 4, 5, p["core"])
	# Trailing tail licks below (flicker with fi parity).
	var wob := 1 if (fi & 1) == 1 else -1
	_fill(img, ox, oy, 11 + wob, top + 12, 2, 3, p["body"])
	_fill(img, ox, oy, 11 - wob, top + 16, 1, 2, p["body_sh"])
	_px(img, ox, oy, 12 + wob, top + 19, p["body_sh"])

	# Eyes (front/side only — the flame's "face").
	match dir:
		DIR_DOWN:
			_fill(img, ox, oy, 10, top + 5, 1, 2, p["eye"])
			_fill(img, ox, oy, 13, top + 5, 1, 2, p["eye"])
		DIR_SIDE:
			_fill(img, ox, oy, 13, top + 5, 1, 2, p["eye"])
		DIR_UP:
			pass

# --- beetle (armored crawler; desert/savanna) -----------------------------------
const BEETLE_STEP: Array[int] = [0, 1, 0, 0, 1, 0]  # 6-frame leg scuttle parity

func _draw_beetle(img: Image, ox: int, oy: int, dir: int, p: Dictionary, kind: String, fi: int) -> void:
	var lunge := 0
	var step := 0
	match kind:
		"idle":
			step = 0
		"walk":
			step = 1 if (fi % 2) == 1 else 0
		"attack":
			lunge = SLIME_ATTACK_LUNGE[fi]
	var lx := 0
	var ly := 0
	match dir:
		DIR_SIDE:
			lx = lunge
		DIR_UP:
			ly = -lunge
		DIR_DOWN:
			ly = lunge

	if dir == DIR_SIDE:
		# Shell dome, head to the right. (lunge rides the LOCAL coords so the
		# fill clamp keeps every pose inside its own frame.)
		_fill(img, ox, oy, 4 + lx, 17, 12, 8, p["body"])
		_fill(img, ox, oy, 5 + lx, 15, 10, 3, p["body"])
		_fill(img, ox, oy, 5 + lx, 15, 6, 2, p["body_hi"])       # lit shell top
		_fill(img, ox, oy, 4 + lx, 23, 12, 2, p["body_sh"])      # shell underside
		_fill(img, ox, oy, 15 + lx, 19, 4, 5, p["body_sh"])      # head
		_fill(img, ox, oy, 17 + lx, 20, 1, 1, p["eye"])
		_fill(img, ox, oy, 18 + lx, 22, 3, 1, p["horn"])         # mandible
		if lunge > 0:
			_fill(img, ox, oy, 19 + lx, 20, 3, 1, p["horn"])     # raised horn on strike
		# Legs: 3 visible, alternate pairs step.
		for i in 3:
			var lx2 := 6 + i * 4 + lx
			var lift := step if (i % 2) == 0 else (1 - step)
			_fill(img, ox, oy, lx2, 25 - lift, 2, 3 + lift, p["horn"])
	else:
		# Top-ish front/back view: oval shell with a seam, head at the bottom (DOWN).
		_fill(img, ox, oy, 6, 14 + ly, 12, 11, p["body"])
		_fill(img, ox, oy, 7, 12 + ly, 10, 3, p["body"])
		_fill(img, ox, oy, 7, 12 + ly, 10, 2, p["body_hi"])      # lit crown
		_fill(img, ox, oy, 11, 12 + ly, 2, 13, p["belly"])       # wing-case seam
		_fill(img, ox, oy, 6, 23 + ly, 12, 2, p["body_sh"])
		_fill(img, ox, oy, 7, 14 + ly, 1, 9, p["body_hi"])       # lit left flank
		_fill(img, ox, oy, 16, 14 + ly, 1, 9, p["body_sh"])      # shaded right
		if dir == DIR_DOWN:
			_fill(img, ox, oy, 9, 25 + ly, 6, 3, p["body_sh"])   # head
			_fill(img, ox, oy, 9, 26 + ly, 1, 1, p["eye"])
			_fill(img, ox, oy, 14, 26 + ly, 1, 1, p["eye"])
			var mopen := 1 if lunge > 0 else 0
			_fill(img, ox, oy, 8, 27 + mopen + ly, 2, 1, p["horn"])   # mandibles
			_fill(img, ox, oy, 14, 27 + mopen + ly, 2, 1, p["horn"])
		# Legs poking out both flanks, alternating.
		for i in 3:
			var lyy := 15 + i * 4 + ly
			var lift2 := step if (i % 2) == 0 else (1 - step)
			_fill(img, ox, oy, 4 - lift2, lyy, 2, 2, p["horn"])
			_fill(img, ox, oy, 18 + lift2, lyy, 2, 2, p["horn"])

# --- raid bosses ---------------------------------------------------------------
## Bespoke 64x64 boss sheets, one per BossDefs kit: 640x128, 10 cols x 2 rows.
## Row 0 = FRONT (used for both down and up facings — bosses read fine without a
## dedicated back), row 1 = SIDE (left = flip_h). Cols = idle(0-1) walk(2-5)
## attack(6-9); fewer walk frames than players buys more pixels per frame.
const BOSS_FRAME := 64
const BOSS_COLS := 10
const BOSS_ROWS := 2
const BOSS_IDLE_COLS: Array[int] = [0, 1]
const BOSS_WALK_COLS: Array[int] = [2, 3, 4, 5]
const BOSS_ATTACK_COLS: Array[int] = [6, 7, 8, 9]
const BOSS_WALK_SWING: Array[int] = [0, 2, 0, -2]
const BOSS_WALK_BOB: Array[int] = [0, 1, 0, 1]
# Lava fissure path across the Magma Titan's torso (frame-local px).
const TITAN_CRACKS: Array[Vector2i] = [
	Vector2i(24, 28), Vector2i(25, 29), Vector2i(26, 30), Vector2i(27, 30), Vector2i(28, 31),
	Vector2i(29, 32), Vector2i(31, 33), Vector2i(33, 33), Vector2i(35, 34), Vector2i(36, 35),
	Vector2i(38, 36), Vector2i(39, 37), Vector2i(30, 38), Vector2i(31, 39), Vector2i(32, 40),
]

func _bake_boss(kit: int) -> Image:
	var img := _new_sheet(BOSS_FRAME * BOSS_COLS, BOSS_FRAME * BOSS_ROWS)
	for row in BOSS_ROWS:
		var oy := row * BOSS_FRAME
		var side := row == 1
		for i in BOSS_IDLE_COLS.size():
			_boss_frame(img, BOSS_IDLE_COLS[i] * BOSS_FRAME, oy, kit, side, "idle", i)
		for i in BOSS_WALK_COLS.size():
			_boss_frame(img, BOSS_WALK_COLS[i] * BOSS_FRAME, oy, kit, side, "walk", i)
		for i in BOSS_ATTACK_COLS.size():
			_boss_frame(img, BOSS_ATTACK_COLS[i] * BOSS_FRAME, oy, kit, side, "attack", i)
	return img

func _boss_frame(img: Image, ox: int, oy: int, kit: int, side: bool, kind: String, fi: int) -> void:
	match kit:
		1:
			_draw_wyrm(img, ox, oy, side, _frost, kind, fi)
			_outline_frame(img, ox, oy, _frost["outline"], BOSS_FRAME, BOSS_FRAME)
		2:
			_draw_horror(img, ox, oy, side, _horror, kind, fi)
			_outline_frame(img, ox, oy, _horror["outline"], BOSS_FRAME, BOSS_FRAME)
		_:
			_draw_titan(img, ox, oy, side, _magma, kind, fi)
			_outline_frame(img, ox, oy, _magma["outline"], BOSS_FRAME, BOSS_FRAME)
	_boss_shadow(img, ox, oy)

func _boss_shadow(img: Image, ox: int, oy: int) -> void:
	for xx in range(16, 48):
		CharPainterScript._shadow_px(img, ox, oy, xx, 60)
	for xx in range(12, 52):
		CharPainterScript._shadow_px(img, ox, oy, xx, 61)
	for xx in range(20, 44):
		CharPainterScript._shadow_px(img, ox, oy, xx, 62)

## Boss-frame fill (clamped to the 64x64 boss frame).
func _bfill(img: Image, ox: int, oy: int, lx: int, ly: int, w: int, h: int, col: Color) -> void:
	CharPainterScript.fill(img, ox, oy, lx, ly, w, h, col, BOSS_FRAME, BOSS_FRAME)

# --- Magma Titan: broad rock golem, lava-crack belly, smashing fists ------------
func _draw_titan(img: Image, ox: int, oy: int, side: bool, p: Dictionary, kind: String, fi: int) -> void:
	var b := 0
	var swing := 0
	var pose := ""
	match kind:
		"idle":
			b = 1 if fi == 1 else 0
		"walk":
			swing = BOSS_WALK_SWING[fi]
			b = BOSS_WALK_BOB[fi]
		"attack":
			pose = "wind" if (fi == 0 or fi == 3) else "strike"
	var rock: Color = p["rock"]
	var rock_hi: Color = p["rock_hi"]
	var rock_sh: Color = p["rock_sh"]
	var lava: Color = p["lava"]
	var lava_hi: Color = p["lava_hi"]

	if side:
		# Torso + head, facing right.
		_bfill(img, ox, oy, 16, 22 + b, 28, 26, rock)
		_bfill(img, ox, oy, 16, 22 + b, 28, 3, rock_hi)
		_bfill(img, ox, oy, 16, 45 + b, 28, 3, rock_sh)
		_bfill(img, ox, oy, 30, 10 + b, 14, 13, rock)          # head
		_bfill(img, ox, oy, 30, 10 + b, 14, 2, rock_hi)
		_bfill(img, ox, oy, 39, 15 + b, 3, 2, lava_hi)         # eye
		_bfill(img, ox, oy, 24, 16 + b, 16, 8, rock_hi)        # shoulder boulder
		# Lava seam down the flank.
		for i in 8:
			_px(img, ox, oy, 22 + i, 30 + b + (i % 3), lava, BOSS_FRAME, BOSS_FRAME)
			_px(img, ox, oy, 22 + i, 31 + b + (i % 3), lava_hi if i % 2 == 0 else lava, BOSS_FRAME, BOSS_FRAME)
		# Front arm by pose.
		match pose:
			"wind":
				_bfill(img, ox, oy, 34, 6, 8, 18, rock)        # arm raised high
				_bfill(img, ox, oy, 33, 2, 10, 8, rock_sh)     # fist overhead
			"strike":
				_bfill(img, ox, oy, 36, 30 + b, 18, 8, rock)   # arm rammed forward (rooted in torso)
				_bfill(img, ox, oy, 48, 27 + b, 11, 13, rock_sh)  # fist
				_bfill(img, ox, oy, 52, 30 + b, 3, 2, lava_hi)  # impact spark
			_:
				var asw := -(swing >> 1)
				_bfill(img, ox, oy, 36, 26 + b + asw, 8, 20, rock)
				_bfill(img, ox, oy, 35, 44 + b + asw, 10, 9, rock_sh)  # fist
		# Legs.
		var front := 1 if swing > 0 else 0
		var back := 1 if swing < 0 else 0
		_bfill(img, ox, oy, 20, 46 + b + back, 8, 12, rock_sh)
		_bfill(img, ox, oy, 31, 46 + b + front, 8, 12, rock_sh)
		_bfill(img, ox, oy, 20, 56 + b + back, 8, 3, p["outline"])
		_bfill(img, ox, oy, 31, 56 + b + front, 8, 3, p["outline"])
	else:
		# Head.
		_bfill(img, ox, oy, 26, 10 + b, 12, 12, rock)
		_bfill(img, ox, oy, 26, 10 + b, 12, 2, rock_hi)
		_bfill(img, ox, oy, 28, 15 + b, 3, 2, lava_hi)         # glowing eyes
		_bfill(img, ox, oy, 33, 15 + b, 3, 2, lava_hi)
		_bfill(img, ox, oy, 28, 14 + b, 8, 1, rock_sh)         # brow
		# Torso.
		_bfill(img, ox, oy, 18, 20 + b, 28, 27, rock)
		_bfill(img, ox, oy, 18, 20 + b, 28, 3, rock_hi)
		_bfill(img, ox, oy, 18, 44 + b, 28, 3, rock_sh)
		_bfill(img, ox, oy, 18, 22 + b, 2, 22, rock_hi)        # lit left flank
		_bfill(img, ox, oy, 44, 22 + b, 2, 22, rock_sh)        # shaded right
		# Molten core glowing through the belly + crack network radiating from it.
		_bfill(img, ox, oy, 27, 34 + b, 10, 8, lava)
		_bfill(img, ox, oy, 29, 36 + b, 6, 4, lava_hi)
		for c in TITAN_CRACKS:
			_px(img, ox, oy, c.x, c.y + b, lava, BOSS_FRAME, BOSS_FRAME)
			_px(img, ox, oy, c.x + 1, c.y + b, lava_hi, BOSS_FRAME, BOSS_FRAME)
		# Shoulders (boulders).
		_bfill(img, ox, oy, 8, 18 + b, 12, 10, rock)
		_bfill(img, ox, oy, 8, 18 + b, 12, 2, rock_hi)
		_bfill(img, ox, oy, 44, 18 + b, 12, 10, rock)
		_bfill(img, ox, oy, 44, 18 + b, 12, 2, rock_hi)
		# Arms + fists by pose.
		match pose:
			"wind":
				_bfill(img, ox, oy, 6, 8, 8, 14, rock)         # both arms raised
				_bfill(img, ox, oy, 50, 8, 8, 14, rock)
				_bfill(img, ox, oy, 4, 2, 11, 9, rock_sh)      # fists overhead
				_bfill(img, ox, oy, 49, 2, 11, 9, rock_sh)
			"strike":
				_bfill(img, ox, oy, 8, 28 + b, 8, 20, rock)
				_bfill(img, ox, oy, 48, 28 + b, 8, 20, rock)
				_bfill(img, ox, oy, 5, 46 + b, 12, 10, rock_sh)  # fists slammed down
				_bfill(img, ox, oy, 47, 46 + b, 12, 10, rock_sh)
				_bfill(img, ox, oy, 3, 54 + b, 4, 2, lava_hi)  # impact sparks
				_bfill(img, ox, oy, 57, 54 + b, 4, 2, lava_hi)
			_:
				var asw2 := swing >> 1
				_bfill(img, ox, oy, 8, 26 + b + asw2, 8, 20, rock)
				_bfill(img, ox, oy, 48, 26 + b - asw2, 8, 20, rock)
				_bfill(img, ox, oy, 7, 44 + b + asw2, 10, 9, rock_sh)   # fists
				_bfill(img, ox, oy, 47, 44 + b - asw2, 10, 9, rock_sh)
		# Legs.
		var l := 1 if swing > 0 else 0
		var r := 1 if swing < 0 else 0
		_bfill(img, ox, oy, 21, 46 + b + l, 9, 12, rock_sh)
		_bfill(img, ox, oy, 34, 46 + b + r, 9, 12, rock_sh)
		_bfill(img, ox, oy, 21, 56 + b + l, 9, 3, p["outline"])
		_bfill(img, ox, oy, 34, 56 + b + r, 9, 3, p["outline"])

# --- Frost Wyrm: crystalline serpent, rearing lunge ------------------------------
func _draw_wyrm(img: Image, ox: int, oy: int, side: bool, p: Dictionary, kind: String, fi: int) -> void:
	var b := 0
	var slither := 0
	var pose := ""
	match kind:
		"idle":
			b = 1 if fi == 1 else 0
		"walk":
			slither = BOSS_WALK_SWING[fi]
			b = BOSS_WALK_BOB[fi]
		"attack":
			pose = "wind" if (fi == 0 or fi == 3) else "strike"
	var ice: Color = p["ice"]
	var ice_hi: Color = p["ice_hi"]
	var ice_sh: Color = p["ice_sh"]
	var crystal: Color = p["crystal"]
	var deep: Color = p["deep"]
	var head_dy := 0
	if pose == "wind":
		head_dy = -4
	elif pose == "strike":
		head_dy = 4

	if side:
		# Coiled body: two humps + tail, head rearing to the right.
		_bfill(img, ox, oy, 8, 40 + b, 40, 16, ice)                 # base coil
		_bfill(img, ox, oy, 8, 40 + b, 40, 3, ice_hi)
		_bfill(img, ox, oy, 8, 53 + b, 40, 3, ice_sh)
		_bfill(img, ox, oy, 12 + slither, 30 + b, 18, 12, ice)      # rear hump
		_bfill(img, ox, oy, 12 + slither, 30 + b, 18, 2, ice_hi)
		_bfill(img, ox, oy, 2, 46 + b, 8, 6, ice_sh)                # tail tip
		# Neck arcing up-right.
		_bfill(img, ox, oy, 34, 22 + b + head_dy, 10, 20, ice)
		_bfill(img, ox, oy, 34, 22 + b + head_dy, 3, 20, ice_hi)
		# Head + jaw.
		_bfill(img, ox, oy, 38, 10 + b + head_dy, 18, 12, ice)
		_bfill(img, ox, oy, 38, 10 + b + head_dy, 18, 2, ice_hi)
		_bfill(img, ox, oy, 36, 4 + b + head_dy, 4, 8, crystal)     # horn
		_bfill(img, ox, oy, 48, 13 + b + head_dy, 3, 2, p["eye"])
		if pose == "strike":
			_bfill(img, ox, oy, 44, 20 + b + head_dy, 14, 5, p["maw"])   # open maw
			_bfill(img, ox, oy, 45, 20 + b + head_dy, 2, 2, crystal)     # fangs
			_bfill(img, ox, oy, 53, 20 + b + head_dy, 2, 2, crystal)
			_bfill(img, ox, oy, 44, 25 + b + head_dy, 12, 4, ice_sh)     # lower jaw
		else:
			_bfill(img, ox, oy, 44, 20 + b + head_dy, 12, 4, ice_sh)     # closed snout
		# Back spines along the coil.
		for i in 5:
			var sx := 12 + i * 8 + slither
			_bfill(img, ox, oy, sx, 36 + b, 2, 4, crystal)
			_px(img, ox, oy, sx, 35 + b, crystal, BOSS_FRAME, BOSS_FRAME)
		_bfill(img, ox, oy, 14, 46 + b, 26, 2, deep)                # belly seam
	else:
		# Front: stacked coils, head rising center.
		_bfill(img, ox, oy, 14, 44 + b, 36, 12, ice)                # bottom coil
		_bfill(img, ox, oy, 14, 44 + b, 36, 2, ice_hi)
		_bfill(img, ox, oy, 14, 53 + b, 36, 3, ice_sh)
		_bfill(img, ox, oy, 18 + slither, 34 + b, 28, 12, ice)      # middle coil
		_bfill(img, ox, oy, 18 + slither, 34 + b, 28, 2, ice_hi)
		_bfill(img, ox, oy, 22 - slither, 26 + b, 20, 10, ice)      # upper coil
		_bfill(img, ox, oy, 22 - slither, 26 + b, 20, 2, ice_hi)
		# Neck + head.
		_bfill(img, ox, oy, 27, 16 + b + head_dy, 10, 14, ice)
		_bfill(img, ox, oy, 24, 6 + b + head_dy, 16, 12, ice)
		_bfill(img, ox, oy, 24, 6 + b + head_dy, 16, 2, ice_hi)
		_bfill(img, ox, oy, 20, 2 + b + head_dy, 4, 8, crystal)     # horns
		_bfill(img, ox, oy, 40, 2 + b + head_dy, 4, 8, crystal)
		_bfill(img, ox, oy, 27, 11 + b + head_dy, 3, 2, p["eye"])   # glowing eyes
		_bfill(img, ox, oy, 34, 11 + b + head_dy, 3, 2, p["eye"])
		if pose == "strike":
			_bfill(img, ox, oy, 27, 15 + b + head_dy, 10, 4, p["maw"])   # open maw
			_px(img, ox, oy, 28, 15 + b + head_dy, crystal, BOSS_FRAME, BOSS_FRAME)
			_px(img, ox, oy, 35, 15 + b + head_dy, crystal, BOSS_FRAME, BOSS_FRAME)
		# Crystal spines on the coil tops.
		for i in 4:
			var sx2 := 20 + i * 8
			_bfill(img, ox, oy, sx2 + slither, 32 + b, 2, 3, crystal)
			_bfill(img, ox, oy, sx2 - slither, 42 + b, 2, 3, crystal)
		_bfill(img, ox, oy, 24, 48 + b, 16, 2, deep)                # belly seam

# --- Swamp Horror: mound of moss, many eyes, slamming tendrils -------------------
func _draw_horror(img: Image, ox: int, oy: int, side: bool, p: Dictionary, kind: String, fi: int) -> void:
	var b := 0
	var lean := 0
	var pose := ""
	match kind:
		"idle":
			b = 1 if fi == 1 else 0
		"walk":
			lean = BOSS_WALK_SWING[fi] >> 1
			b = BOSS_WALK_BOB[fi]
		"attack":
			pose = "wind" if (fi == 0 or fi == 3) else "strike"
	var moss: Color = p["moss"]
	var moss_hi: Color = p["moss_hi"]
	var moss_sh: Color = p["moss_sh"]
	var vine: Color = p["vine"]
	var vine_hi: Color = p["vine_hi"]

	# The mound reads the same from every angle; side view just leans forward and
	# shifts the eye cluster toward the facing.
	var ex := 6 if side else 0   # eye-cluster shift toward +x when side-facing
	# Mound (stacked domes).
	_bfill(img, ox, oy, 18 + lean, 24 + b, 28, 10, moss)
	_bfill(img, ox, oy, 18 + lean, 24 + b, 28, 2, moss_hi)
	_bfill(img, ox, oy, 14 + lean, 32 + b, 36, 14, moss)
	_bfill(img, ox, oy, 12, 44 + b, 40, 14, moss)
	_bfill(img, ox, oy, 12, 54 + b, 40, 4, moss_sh)
	_bfill(img, ox, oy, 14 + lean, 32 + b, 2, 12, moss_hi)      # lit left
	_bfill(img, ox, oy, 47 + lean, 32 + b, 2, 12, moss_sh)      # shaded right
	# Moss drips / texture clumps.
	for i in 6:
		var cx := 16 + i * 6 + lean
		_bfill(img, ox, oy, cx, 28 + b + (i % 3) * 9, 3, 2, vine_hi)
	# Eyes (a scattered cluster; one blinks on idle frame 1).
	_horror_eye(img, ox, oy, 22 + ex, 34 + b, p, kind == "idle" and fi == 1)
	_horror_eye(img, ox, oy, 30 + ex, 30 + b, p, false)
	_horror_eye(img, ox, oy, 38 + ex, 35 + b, p, false)
	_horror_eye(img, ox, oy, 26 + ex, 42 + b, p, false)
	_horror_eye(img, ox, oy, 36 + ex, 44 + b, p, kind == "idle" and fi == 1)
	# Maw gapes on the strike.
	if pose == "strike":
		_bfill(img, ox, oy, 26 + ex, 50 + b, 12, 6, p["maw"])
		_bfill(img, ox, oy, 28 + ex, 50 + b, 2, 2, moss_hi)     # tooth nubs
		_bfill(img, ox, oy, 34 + ex, 50 + b, 2, 2, moss_hi)
	# Tendrils.
	match pose:
		"wind":
			# Raised, quivering above the mound.
			_bfill(img, ox, oy, 6, 18, 4, 22, vine)
			_bfill(img, ox, oy, 54, 18, 4, 22, vine)
			_bfill(img, ox, oy, 5, 14, 6, 5, vine_hi)           # tips curled
			_bfill(img, ox, oy, 53, 14, 6, 5, vine_hi)
		"strike":
			# Slammed flat and wide.
			_bfill(img, ox, oy, 2, 50 + b, 12, 5, vine)
			_bfill(img, ox, oy, 50, 50 + b, 12, 5, vine)
			_bfill(img, ox, oy, 2, 48 + b, 4, 3, vine_hi)
			_bfill(img, ox, oy, 58, 48 + b, 4, 3, vine_hi)
		_:
			# Drooping at the flanks, dragging with the walk lean.
			_bfill(img, ox, oy, 7 + lean, 38 + b, 5, 4, vine)
			_bfill(img, ox, oy, 5 + lean, 42 + b, 4, 12, vine)
			_bfill(img, ox, oy, 52 - lean, 38 + b, 5, 4, vine)
			_bfill(img, ox, oy, 55 - lean, 42 + b, 4, 12, vine)

func _horror_eye(img: Image, ox: int, oy: int, x: int, y: int, p: Dictionary, blink: bool) -> void:
	if blink:
		_bfill(img, ox, oy, x, y + 1, 3, 1, p["moss_sh"])
		return
	_bfill(img, ox, oy, x, y, 3, 3, p["eye"])
	_px(img, ox, oy, x + 1, y + 1, p["outline"], BOSS_FRAME, BOSS_FRAME)

# --- fx sheets -------------------------------------------------------------------
# All combat/spell effects are baked animated strips (frames left-to-right,
# directional ones authored pointing +X). Most are baked NEUTRAL (white/greys)
# and tinted per effect at runtime by EffectSpawner — one ring sheet serves
# slam/smash/nova via tint + node scale.

## Per-pixel helpers (deterministic float math, no rng).
func _fx_disc(img: Image, ox: int, cx: float, cy: float, r: float, col: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for yy in range(maxi(0, int(cy - r) - 1), mini(h, int(cy + r) + 2)):
		for xx in range(maxi(0, int(cx - r) - 1), mini(int(cx + r) + 2, w - ox)):
			if Vector2(float(xx) - cx, float(yy) - cy).length() <= r:
				img.set_pixelv(Vector2i(ox + xx, yy), col)

func _fx_ring(img: Image, ox: int, fw: int, cx: float, cy: float, r_in: float, r_out: float, col: Color) -> void:
	var h := img.get_height()
	for yy in range(maxi(0, int(cy - r_out) - 1), mini(h, int(cy + r_out) + 2)):
		for xx in range(maxi(0, int(cx - r_out) - 1), mini(int(cx + r_out) + 2, fw)):
			var d := Vector2(float(xx) - cx, float(yy) - cy).length()
			if d >= r_in and d <= r_out:
				img.set_pixelv(Vector2i(ox + xx, yy), col)

func _fx_seg(img: Image, ox: int, fw: int, from: Vector2, to: Vector2, col: Color) -> void:
	var h := img.get_height()
	var steps := int(from.distance_to(to)) * 2 + 1
	for i in steps + 1:
		var p := from.lerp(to, float(i) / float(steps))
		var x := int(round(p.x))
		var y := int(round(p.y))
		if x >= 0 and y >= 0 and x < fw and y < h:
			img.set_pixelv(Vector2i(ox + x, y), col)

## Melee slash: 6 frames, 48x48, a 120-degree cone sweep (MeleeSwing.ARC_DEGREES)
## pivoting near the attacker at the frame's left, authored pointing +X.
func _bake_slash() -> Image:
	var fw := 48
	var img := Image.create_empty(fw * 6, 48, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	var cx := 8.0
	var cy := 24.0
	var half := deg_to_rad(60.0)
	for f in 6:
		var ox := f * fw
		var t := float(f) / 5.0
		var radius: float = 16.0 + t * 18.0
		var alpha: float = 1.0 if f < 3 else (1.0 - 0.28 * float(f - 2))
		var col: Color = Color.html("#ffffff") if f == 0 else (Color.html("#ffe9a8") if f <= 3 else Color.html("#ff8a3c"))
		col.a = alpha
		var a_start: float = -half + half * 0.6 * t
		var a_end := half
		var steps := 72
		for i in steps + 1:
			var ang: float = lerp(a_start, a_end, float(i) / float(steps))
			var lead: bool = i >= steps - 3
			for rr in range(int(radius) - 5, int(radius) + 1):
				var x := int(round(cx + cos(ang) * float(rr)))
				var y := int(round(cy + sin(ang) * float(rr)))
				if x >= 0 and y >= 0 and x < fw and y < 48:
					var pc: Color = col
					if rr <= int(radius) - 3 or lead:
						pc = Color(1.0, 1.0, 1.0, alpha)
					img.set_pixelv(Vector2i(ox + x, y), pc)
		# Speedlines flying off the blade tip mid-swing.
		if f >= 1 and f <= 4:
			var tip := Vector2(cx, cy) + Vector2.from_angle(a_end - 0.1) * radius
			_fx_seg(img, ox, fw, tip, tip + Vector2.from_angle(a_end + 0.5) * 6.0, Color(1, 1, 1, alpha * 0.8))
	return img

## Impact flash: 5 frames 24x24 — expanding core + 6 spokes. Neutral warm-white.
func _bake_impact() -> Image:
	var fw := 24
	var img := Image.create_empty(fw * 5, 24, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 5:
		var ox := f * fw
		var t := float(f) / 4.0
		var fade := 1.0 - t * 0.85
		_fx_disc(img, ox, 12.0, 12.0, 2.0 + 5.0 * t, Color(1.0, 0.95, 0.8, fade))
		_fx_disc(img, ox, 12.0, 12.0, 1.0 + 2.0 * t, Color(1, 1, 1, fade))
		for i in 6:
			var dir := Vector2.from_angle(TAU * float(i) / 6.0 + 0.35)
			var a := Vector2(12, 12) + dir * (3.0 + 5.0 * t)
			var b := Vector2(12, 12) + dir * (5.0 + 8.0 * t)
			_fx_seg(img, ox, fw, a, b, Color(1.0, 1.0, 0.9, fade))
	return img

## Dash puff: 5 frames 32x32 — dust chevrons + puffs drifting -X (behind the dash).
func _bake_dash() -> Image:
	var fw := 32
	var img := Image.create_empty(fw * 5, 32, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 5:
		var ox := f * fw
		var t := float(f) / 4.0
		var fade := 1.0 - t
		for i in 3:
			var x := 22.0 - 6.0 * float(i) - 8.0 * t
			var a := fade * (1.0 - 0.22 * float(i))
			var c := Color(0.94, 0.96, 1.0, a * 0.9)
			_fx_seg(img, ox, fw, Vector2(x, 16), Vector2(x - 5, 11), c)
			_fx_seg(img, ox, fw, Vector2(x, 16), Vector2(x - 5, 21), c)
			_fx_disc(img, ox, x - 7.0, 16.0 + (3.0 if i == 1 else -3.0), 1.5 + t, Color(0.9, 0.92, 0.98, a * 0.35))
	return img

## Heal column: 8 frames 32x48 — soft light column + plus-sparkles rising from the
## feet (frame bottom-center is the caster's feet). Neutral white; tinted green.
func _bake_heal() -> Image:
	var fw := 32
	var img := Image.create_empty(fw * 8, 48, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 8:
		var ox := f * fw
		var t := float(f) / 7.0
		var fade: float = minf(1.0, 2.5 * (1.0 - t))
		# Soft column, brightest early.
		for yy in range(8, 44):
			var ca := 0.14 * fade * (1.0 - float(yy - 8) / 36.0 * 0.5)
			for xx in range(10, 22):
				img.set_pixelv(Vector2i(ox + xx, yy), Color(1, 1, 1, ca))
		# Rising sparkles (staggered).
		for i in 4:
			var sy := 40.0 - 28.0 * t - 5.0 * float(i)
			if sy < 6.0:
				continue
			var sx := 8.0 + float((i * 7) % 17)
			var sa := fade * (1.0 - 0.15 * float(i))
			_fx_seg(img, ox, fw, Vector2(sx - 2, sy), Vector2(sx + 2, sy), Color(1, 1, 1, sa))
			_fx_seg(img, ox, fw, Vector2(sx, sy - 2), Vector2(sx, sy + 2), Color(1, 1, 1, sa))
	return img

## Neutral shockwave ring: 8 frames 64x64 expanding to r=28. EffectSpawner tints
## and node-scales it per effect (slam/smash/nova), so one sheet serves all rings.
func _bake_ring() -> Image:
	var fw := 64
	var img := Image.create_empty(fw * 8, 64, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 8:
		var ox := f * fw
		var t := float(f) / 7.0
		var r := 4.0 + 24.0 * t
		var fade := 1.0 - t * 0.9
		_fx_ring(img, ox, fw, 32.0, 32.0, r - 2.5, r, Color(1, 1, 1, fade))
		_fx_ring(img, ox, fw, 32.0, 32.0, r - 4.0, r - 2.5, Color(1, 1, 1, fade * 0.45))
		if r > 9.0:
			_fx_ring(img, ox, fw, 32.0, 32.0, r * 0.6 - 1.0, r * 0.6, Color(1, 1, 1, fade * 0.35))
	return img

## Summon burst: 7 frames 48x48 — light motes imploding into a dark core. Greys;
## tinted purple at runtime.
func _bake_summon() -> Image:
	var fw := 48
	var img := Image.create_empty(fw * 7, 48, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 7:
		var ox := f * fw
		var t := float(f) / 6.0
		var rr := 20.0 * (1.0 - t) + 3.0
		for i in 8:
			var dir := Vector2.from_angle(TAU * float(i) / 8.0 + t * 1.2)
			var p := Vector2(24, 24) + dir * rr
			_fx_disc(img, ox, p.x, p.y, 1.6, Color(0.95, 0.95, 1.0, 0.5 + 0.5 * t))
		_fx_disc(img, ox, 24.0, 24.0, 2.0 + 5.0 * t, Color(0.25, 0.22, 0.3, 0.6 + 0.3 * t))
		_fx_disc(img, ox, 24.0, 24.0, 1.0 + 2.0 * t, Color(0.6, 0.55, 0.7, 0.8))
	return img

## Charge windup dust: 6 frames 32x32 — dirt kicked back at the feet, alternating.
func _bake_charge() -> Image:
	var fw := 32
	var img := Image.create_empty(fw * 6, 32, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 6:
		var ox := f * fw
		var side := 1.0 if (f % 2) == 0 else -1.0
		var t := float(f) / 5.0
		for i in 3:
			var px2 := 16.0 - side * (4.0 + 4.0 * float(i)) - 4.0 * t
			var py2 := 24.0 - float(i) * 2.0 - 2.0 * t
			var a := (1.0 - 0.25 * float(i)) * (0.9 - 0.4 * t)
			_fx_disc(img, ox, px2, py2, 1.5 + 0.5 * float(i), Color(0.85, 0.8, 0.72, a * 0.8))
	return img

## Bolt core: 4-frame 16x16 loop — bright shimmering orb (the projectile body).
func _bake_bolt() -> Image:
	var fw := 16
	var img := Image.create_empty(fw * 4, 16, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 4:
		var ox := f * fw
		_fx_disc(img, ox, 8.0, 8.0, 5.0, Color(1.0, 0.82, 0.45, 0.35))
		_fx_disc(img, ox, 8.0, 8.0, 3.0, Color(1.0, 0.9, 0.6, 0.95))
		_fx_disc(img, ox, 8.0, 8.0, 1.6, Color(1, 1, 1, 1))
		var orb := Vector2(8, 8) + Vector2.from_angle(TAU * float(f) / 4.0) * 5.0
		_fx_disc(img, ox, orb.x, orb.y, 0.8, Color(1, 1, 1, 0.9))
	return img

## Radial glow: one 64x64 soft white falloff — additive underlay for projectiles,
## and the world glow layer's quad (orbs/shrines/lava at night).
func _bake_glow() -> Image:
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for yy in 64:
		for xx in 64:
			var d := Vector2(float(xx) - 31.5, float(yy) - 31.5).length() / 32.0
			if d < 1.0:
				var a := pow(1.0 - d, 2.2)
				img.set_pixelv(Vector2i(xx, yy), Color(1, 1, 1, a))
	return img

## Hazard swirl: 4-frame 48x48 loop — three spiral arms rotating (30 deg/frame =
## seamless with the 120-degree arm symmetry). White; kit-tinted at runtime.
func _bake_hazard_fx() -> Image:
	var fw := 48
	var img := Image.create_empty(fw * 4, 48, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for f in 4:
		var ox := f * fw
		var rot := deg_to_rad(30.0) * float(f)
		for arm in 3:
			for s in 26:
				var ang := TAU * float(arm) / 3.0 + float(s) * 0.16 + rot
				var r := 5.0 + float(s) * 0.62
				var p := Vector2(24, 24) + Vector2.from_angle(ang) * r
				var a := 0.75 * (1.0 - float(s) / 30.0)
				_fx_disc(img, ox, p.x, p.y, 1.0, Color(1, 1, 1, a))
	return img

# --- pixel font ------------------------------------------------------------------
## Code-baked bitmap font: the classic 5x7 pixel typeface in 6x9 monospace cells
## (5x7 body + 1px letter spacing + top/bottom padding), ASCII 32..126, 16 cols x
## 6 rows atlas (96x54). Emitted as assets/fonts/pixel.png + a plain-text BMFont
## descriptor pixel.fnt (Godot 4 imports .fnt natively as a bitmap FontFile).
## Use it at size 9 (or 18 — integer multiples only, nearest filter).
##
## Glyph data: 5 column-bytes per char, bit 0 = top row, bits 0-6 used — the
## de-facto standard 5x7 LCD font layout.
const FONT_FIRST := 32
const FONT_LAST := 126
const FONT_CELL_W := 6
const FONT_CELL_H := 9
const FONT5X7: PackedInt32Array = [
	0x00, 0x00, 0x00, 0x00, 0x00,  # 32 ' '
	0x00, 0x00, 0x5F, 0x00, 0x00,  # 33 '!'
	0x00, 0x07, 0x00, 0x07, 0x00,  # 34 '"'
	0x14, 0x7F, 0x14, 0x7F, 0x14,  # 35 '#'
	0x24, 0x2A, 0x7F, 0x2A, 0x12,  # 36 '$'
	0x23, 0x13, 0x08, 0x64, 0x62,  # 37 '%'
	0x36, 0x49, 0x55, 0x22, 0x50,  # 38 '&'
	0x00, 0x05, 0x03, 0x00, 0x00,  # 39 '''
	0x00, 0x1C, 0x22, 0x41, 0x00,  # 40 '('
	0x00, 0x41, 0x22, 0x1C, 0x00,  # 41 ')'
	0x14, 0x08, 0x3E, 0x08, 0x14,  # 42 '*'
	0x08, 0x08, 0x3E, 0x08, 0x08,  # 43 '+'
	0x00, 0x50, 0x30, 0x00, 0x00,  # 44 ','
	0x08, 0x08, 0x08, 0x08, 0x08,  # 45 '-'
	0x00, 0x60, 0x60, 0x00, 0x00,  # 46 '.'
	0x20, 0x10, 0x08, 0x04, 0x02,  # 47 '/'
	0x3E, 0x51, 0x49, 0x45, 0x3E,  # 48 '0'
	0x00, 0x42, 0x7F, 0x40, 0x00,  # 49 '1'
	0x42, 0x61, 0x51, 0x49, 0x46,  # 50 '2'
	0x21, 0x41, 0x45, 0x4B, 0x31,  # 51 '3'
	0x18, 0x14, 0x12, 0x7F, 0x10,  # 52 '4'
	0x27, 0x45, 0x45, 0x45, 0x39,  # 53 '5'
	0x3C, 0x4A, 0x49, 0x49, 0x30,  # 54 '6'
	0x01, 0x71, 0x09, 0x05, 0x03,  # 55 '7'
	0x36, 0x49, 0x49, 0x49, 0x36,  # 56 '8'
	0x06, 0x49, 0x49, 0x29, 0x1E,  # 57 '9'
	0x00, 0x36, 0x36, 0x00, 0x00,  # 58 ':'
	0x00, 0x56, 0x36, 0x00, 0x00,  # 59 ';'
	0x08, 0x14, 0x22, 0x41, 0x00,  # 60 '<'
	0x14, 0x14, 0x14, 0x14, 0x14,  # 61 '='
	0x00, 0x41, 0x22, 0x14, 0x08,  # 62 '>'
	0x02, 0x01, 0x51, 0x09, 0x06,  # 63 '?'
	0x32, 0x49, 0x79, 0x41, 0x3E,  # 64 '@'
	0x7E, 0x11, 0x11, 0x11, 0x7E,  # 65 'A'
	0x7F, 0x49, 0x49, 0x49, 0x36,  # 66 'B'
	0x3E, 0x41, 0x41, 0x41, 0x22,  # 67 'C'
	0x7F, 0x41, 0x41, 0x22, 0x1C,  # 68 'D'
	0x7F, 0x49, 0x49, 0x49, 0x41,  # 69 'E'
	0x7F, 0x09, 0x09, 0x09, 0x01,  # 70 'F'
	0x3E, 0x41, 0x49, 0x49, 0x7A,  # 71 'G'
	0x7F, 0x08, 0x08, 0x08, 0x7F,  # 72 'H'
	0x00, 0x41, 0x7F, 0x41, 0x00,  # 73 'I'
	0x20, 0x40, 0x41, 0x3F, 0x01,  # 74 'J'
	0x7F, 0x08, 0x14, 0x22, 0x41,  # 75 'K'
	0x7F, 0x40, 0x40, 0x40, 0x40,  # 76 'L'
	0x7F, 0x02, 0x0C, 0x02, 0x7F,  # 77 'M'
	0x7F, 0x04, 0x08, 0x10, 0x7F,  # 78 'N'
	0x3E, 0x41, 0x41, 0x41, 0x3E,  # 79 'O'
	0x7F, 0x09, 0x09, 0x09, 0x06,  # 80 'P'
	0x3E, 0x41, 0x51, 0x21, 0x5E,  # 81 'Q'
	0x7F, 0x09, 0x19, 0x29, 0x46,  # 82 'R'
	0x46, 0x49, 0x49, 0x49, 0x31,  # 83 'S'
	0x01, 0x01, 0x7F, 0x01, 0x01,  # 84 'T'
	0x3F, 0x40, 0x40, 0x40, 0x3F,  # 85 'U'
	0x1F, 0x20, 0x40, 0x20, 0x1F,  # 86 'V'
	0x3F, 0x40, 0x38, 0x40, 0x3F,  # 87 'W'
	0x63, 0x14, 0x08, 0x14, 0x63,  # 88 'X'
	0x07, 0x08, 0x70, 0x08, 0x07,  # 89 'Y'
	0x61, 0x51, 0x49, 0x45, 0x43,  # 90 'Z'
	0x00, 0x7F, 0x41, 0x41, 0x00,  # 91 '['
	0x02, 0x04, 0x08, 0x10, 0x20,  # 92 '\'
	0x00, 0x41, 0x41, 0x7F, 0x00,  # 93 ']'
	0x04, 0x02, 0x01, 0x02, 0x04,  # 94 '^'
	0x40, 0x40, 0x40, 0x40, 0x40,  # 95 '_'
	0x00, 0x01, 0x02, 0x04, 0x00,  # 96 '`'
	0x20, 0x54, 0x54, 0x54, 0x78,  # 97 'a'
	0x7F, 0x48, 0x44, 0x44, 0x38,  # 98 'b'
	0x38, 0x44, 0x44, 0x44, 0x20,  # 99 'c'
	0x38, 0x44, 0x44, 0x48, 0x7F,  # 100 'd'
	0x38, 0x54, 0x54, 0x54, 0x18,  # 101 'e'
	0x08, 0x7E, 0x09, 0x01, 0x02,  # 102 'f'
	0x0C, 0x52, 0x52, 0x52, 0x3E,  # 103 'g'
	0x7F, 0x08, 0x04, 0x04, 0x78,  # 104 'h'
	0x00, 0x44, 0x7D, 0x40, 0x00,  # 105 'i'
	0x20, 0x40, 0x44, 0x3D, 0x00,  # 106 'j'
	0x7F, 0x10, 0x28, 0x44, 0x00,  # 107 'k'
	0x00, 0x41, 0x7F, 0x40, 0x00,  # 108 'l'
	0x7C, 0x04, 0x18, 0x04, 0x78,  # 109 'm'
	0x7C, 0x08, 0x04, 0x04, 0x78,  # 110 'n'
	0x38, 0x44, 0x44, 0x44, 0x38,  # 111 'o'
	0x7C, 0x14, 0x14, 0x14, 0x08,  # 112 'p'
	0x08, 0x14, 0x14, 0x18, 0x7C,  # 113 'q'
	0x7C, 0x08, 0x04, 0x04, 0x08,  # 114 'r'
	0x48, 0x54, 0x54, 0x54, 0x20,  # 115 's'
	0x04, 0x3F, 0x44, 0x40, 0x20,  # 116 't'
	0x3C, 0x40, 0x40, 0x20, 0x7C,  # 117 'u'
	0x1C, 0x20, 0x40, 0x20, 0x1C,  # 118 'v'
	0x3C, 0x40, 0x30, 0x40, 0x3C,  # 119 'w'
	0x44, 0x28, 0x10, 0x28, 0x44,  # 120 'x'
	0x0C, 0x50, 0x50, 0x50, 0x3C,  # 121 'y'
	0x44, 0x64, 0x54, 0x4C, 0x44,  # 122 'z'
	0x00, 0x08, 0x36, 0x41, 0x00,  # 123 '{'
	0x00, 0x00, 0x7F, 0x00, 0x00,  # 124 '|'
	0x00, 0x41, 0x36, 0x08, 0x00,  # 125 '}'
	0x02, 0x01, 0x02, 0x04, 0x02,  # 126 '~'
]

func _bake_font() -> Image:
	var count := FONT_LAST - FONT_FIRST + 1
	var img := Image.create_empty(FONT_CELL_W * 16, FONT_CELL_H * 6, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for idx in count:
		var cx := (idx & 15) * FONT_CELL_W
		var cy := (idx >> 4) * FONT_CELL_H
		for col in 5:
			var bits: int = FONT5X7[idx * 5 + col]
			for row in 7:
				if bits & (1 << row):
					img.set_pixelv(Vector2i(cx + col, cy + 1 + row), Color(1, 1, 1))
	return img

## Plain-text BMFont descriptor beside the atlas: Godot's .fnt importer reads it
## natively. Monospace: every glyph advances FONT_CELL_W.
func _write_fnt(path: String) -> int:
	var count := FONT_LAST - FONT_FIRST + 1
	var lines: Array[String] = []
	lines.append('info face="pixel" size=%d bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=0 aa=0 padding=0,0,0,0 spacing=0,0 outline=0' % FONT_CELL_H)
	# Channel spec (BMFont): 0 = holds glyph data, 4 = constant one. Glyphs live
	# in ALPHA, rgb is white — the one combination Godot's importer accepts for
	# plain RGBA pages.
	lines.append("common lineHeight=%d base=8 scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4" % [FONT_CELL_H + 1, FONT_CELL_W * 16, FONT_CELL_H * 6])
	lines.append('page id=0 file="pixel.png"')
	lines.append("chars count=%d" % count)
	for idx in count:
		var code := FONT_FIRST + idx
		var cx := (idx & 15) * FONT_CELL_W
		var cy := (idx >> 4) * FONT_CELL_H
		lines.append("char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=0 xadvance=%d page=0 chnl=15" % [code, cx, cy, FONT_CELL_W, FONT_CELL_H, FONT_CELL_W])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("[ArtBaker] failed to open %s" % path)
		return 1
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("[ArtBaker] wrote %s (%d chars)" % [path, count])
	return 0

# --- skill icons -------------------------------------------------------------------
## assets/sprites/icons_skills.png: 24x24 cells indexed BY ABILITY ID (12 cells;
## the boss-only ids 5-9 stay blank). Pixel versions of the hotbar glyphs.
func _bake_icons() -> Image:
	var cs := 24
	var img := Image.create_empty(cs * 12, cs, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	_icon_melee(img, 0 * cs)
	_icon_bolt(img, 1 * cs)
	_icon_dash(img, 2 * cs)
	_icon_heal(img, 3 * cs)
	_icon_slam(img, 4 * cs)
	_icon_nova(img, 10 * cs)
	_icon_volley(img, 11 * cs)
	return img

## Icon-cell fill (24x24 clamp).
func _ifill(img: Image, ox: int, lx: int, ly: int, w: int, h: int, col: Color) -> void:
	CharPainterScript.fill(img, ox, 0, lx, ly, w, h, col, 24, 24)

func _icon_melee(img: Image, ox: int) -> void:
	var steel := Color.html("#dcdce8")
	var steel_hi := Color.html("#f6f6ff")
	var grip := Color.html("#7a5230")
	for i in 10:  # diagonal blade from bottom-left to top-right
		_ifill(img, ox, 6 + i, 15 - i, 2, 2, steel)
		if i > 4:
			_ifill(img, ox, 6 + i, 15 - i, 1, 1, steel_hi)
	_ifill(img, ox, 7, 14, 5, 2, grip)   # crossguard
	_ifill(img, ox, 4, 17, 4, 4, grip)   # grip

func _icon_bolt(img: Image, ox: int) -> void:
	_fx_disc(img, ox, 14.0, 10.0, 5.0, Color(1.0, 0.82, 0.45, 0.6))
	_fx_disc(img, ox, 14.0, 10.0, 3.2, Color(1.0, 0.9, 0.6, 1.0))
	_fx_disc(img, ox, 14.0, 10.0, 1.5, Color(1, 1, 1))
	_fx_seg(img, ox, 24, Vector2(4, 18), Vector2(10, 13), Color(1.0, 0.85, 0.4, 0.8))

func _icon_dash(img: Image, ox: int) -> void:
	for k in 3:
		var x := 5 + k * 5
		var c := Color(0.7, 0.9, 1.0, 0.55 + 0.22 * float(k))
		for i in 5:
			_ifill(img, ox, x + i, 7 + i, 2, 2, c)
			_ifill(img, ox, x + i, 15 - i, 2, 2, c)

func _icon_heal(img: Image, ox: int) -> void:
	var g := Color(0.4, 1.0, 0.5)
	var g_hi := Color(0.7, 1.0, 0.78)
	_ifill(img, ox, 9, 4, 6, 16, g)
	_ifill(img, ox, 4, 9, 16, 6, g)
	_ifill(img, ox, 10, 5, 2, 14, g_hi)
	_ifill(img, ox, 5, 10, 14, 2, g_hi)

func _icon_slam(img: Image, ox: int) -> void:
	_fx_ring(img, ox, 24, 12.0, 12.0, 7.5, 9.5, Color(1.0, 0.6, 0.3))
	_fx_disc(img, ox, 12.0, 12.0, 3.0, Color(1.0, 0.8, 0.4))

func _icon_nova(img: Image, ox: int) -> void:
	_fx_disc(img, ox, 12.0, 12.0, 3.0, Color(0.85, 0.95, 1.0))
	for k in 8:
		var d := Vector2.from_angle(TAU * float(k) / 8.0)
		var a := Vector2(12, 12) + d * 5.0
		var b := Vector2(12, 12) + d * 10.0
		_fx_seg(img, ox, 24, a, b, Color(0.55, 0.78, 1.0))

func _icon_volley(img: Image, ox: int) -> void:
	for k in 3:
		var d := Vector2.UP.rotated(deg_to_rad(-24.0 + 24.0 * float(k)))
		var base := Vector2(12, 20)
		_fx_seg(img, ox, 24, base, base + d * 14.0, Color(1.0, 0.85, 0.5))
		var tip := base + d * 14.0
		_fx_disc(img, ox, tip.x, tip.y, 1.3, Color(1.0, 0.95, 0.7))

# --- terrain atlas -----------------------------------------------------------
func _bake_terrain() -> Image:
	var ts := 16
	var biomes := [_forest, _desert, _snow, _swamp, _volcano, _savanna]
	var img := Image.create_empty(ts * 6, ts * biomes.size(), false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	for row in biomes.size():
		var b: Dictionary = biomes[row]
		for v in 4:
			_floor_tile(img, v * ts, row * ts, ts, b, v)
		_cliff_tile(img, 4 * ts, row * ts, ts, b)    # col 4 = cliff/rim (island undersides)
		_fringe_tile(img, 5 * ts, row * ts, ts, b)   # col 5 = grass-overhang edge strip
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

## A textured floor tile: a stipple between the biome floor/floor_alt tones plus a
## variant-specific stamp set, so the renderer's 4x4 variant tiling reads as varied
## ground rather than an obvious checker. Variants: 0 = plain, 1 = alt (inverted
## dither), 2 = lush (extra tufts + flower accents), 3 = bare (fissure + dry specks).
func _floor_tile(img: Image, ox: int, oy: int, ts: int, b: Dictionary, variant: int) -> void:
	var alt := variant == 1
	var base: Color = b["floor_alt"] if alt else b["floor"]
	var mix: Color = b["floor"] if alt else b["floor_alt"]
	_dither(img, ox, oy, ts, base, mix, 0.35 if variant == 3 else 0.30)
	var grain: Color = b["shadow"]
	match variant:
		3:
			for s in VAR3_SPECKS:
				img.set_pixelv(Vector2i(ox + s.x, oy + s.y), grain)
			for c in VAR3_CRACK:
				img.set_pixelv(Vector2i(ox + c.x, oy + c.y), b["detail2"])
				img.set_pixelv(Vector2i(ox + c.x, oy + c.y + 1), grain)
		2:
			for s in VAR2_SPECKS:
				img.set_pixelv(Vector2i(ox + s.x, oy + s.y), grain)
			for t in VAR2_TUFTS:
				img.set_pixelv(Vector2i(ox + t.x, oy + t.y), b["detail"])
				img.set_pixelv(Vector2i(ox + t.x, oy + t.y - 1), b["tuft"])
				img.set_pixelv(Vector2i(ox + t.x + 1, oy + t.y - 1), b["tuft"])
				img.set_pixelv(Vector2i(ox + t.x + 1, oy + t.y), b["detail2"])
		_:
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
	var rock_dark: Color = PaletteUtilScript.shade(rock, -1.0)
	var rock_lit: Color = b["wall_top"]
	_dither(img, ox, oy, ts, rock, rock_dark, 0.35)
	for yy in CLIFF_STRATA:
		for xx in ts:
			if (xx + yy) % 4 != 0:            # jagged strata, not ruler-straight
				img.set_pixelv(Vector2i(ox + xx, oy + yy), rock_lit)
				# Contact shadow under each lit stratum makes the relief pop.
				if yy + 1 < ts:
					img.set_pixelv(Vector2i(ox + xx, oy + yy + 1), rock_dark)
	for c in CLIFF_CRACKS:
		img.set_pixelv(Vector2i(ox + c.x, oy + c.y), rock_dark)
		img.set_pixelv(Vector2i(ox + c.x + 1, oy + c.y), rock_dark)

## The grass-overhang fringe strip (atlas col 5): the FloorRenderer tiles this
## along the BOTTOM edge of every island, hanging a few pixels over the cliff
## face below so the plateau lip reads organic instead of ruler-cut.
## Rows 0-3 = solid floor (overlaps the island floor seamlessly), row 4 = the
## shadowed lip line, rows 5+ = ragged hanging blades, rest transparent.
func _fringe_tile(img: Image, ox: int, oy: int, ts: int, b: Dictionary) -> void:
	for yy in 4:
		for xx in ts:
			var thr: float = (float(BAYER4[(yy % 4) * 4 + (xx % 4)]) + 0.5) / 16.0
			var col: Color = b["floor_alt"] if thr < 0.30 else b["floor"]
			img.set_pixelv(Vector2i(ox + xx, oy + yy), col)
	for xx in ts:
		img.set_pixelv(Vector2i(ox + xx, oy + 4), b["shadow"])
		var hang: int = FRINGE_LEN[xx % FRINGE_LEN.size()]
		for i in hang:
			var yy := 5 + i
			if yy < ts:
				img.set_pixelv(Vector2i(ox + xx, oy + yy), b["detail"] if i < hang - 1 else b["detail2"])

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

# --- foliage (trees / grass / rocks / ground decals) ---------------------------
## assets/tiles/foliage.png: 12 cells of 16x24 in 2 rows. Row 0 = tree x3, grass,
## rock x2; row 1 = flower x2, pebbles, crack, stump, bush (ground decals). All
## outlined (except the crack — it is a ground fissure, not a prop) and rooted at
## the cell bottom. Drawn in natural colours; the Foliage renderer applies a subtle
## per-biome tint via modulate. Deterministic (no rng).
func _bake_foliage() -> Image:
	var cw := FOLIAGE_CELL_W   # 16
	var ch := FOLIAGE_CELL_H   # 24
	var cells := 6
	var img := Image.create_empty(cw * cells, ch * 2, false, Image.FORMAT_RGBA8)
	img.fill(TRANSPARENT)
	_tree(img, 0 * cw, "round")
	_tree(img, 1 * cw, "tall")
	_tree(img, 2 * cw, "bushy")
	_grass(img, 3 * cw)
	_rock(img, 4 * cw, false)
	_rock(img, 5 * cw, true)
	_flower(img, 0 * cw, ch, Color.html("#e070a0"))
	_flower(img, 1 * cw, ch, Color.html("#e8c040"))
	_pebbles(img, 2 * cw, ch)
	_crack_decal(img, 3 * cw, ch)
	_stump(img, 4 * cw, ch)
	_bush(img, 5 * cw, ch)
	for c in cells:
		_outline_frame(img, c * cw, 0, Color.html("#1c2418"), cw, ch)
		if c != 3:  # row 1: skip the crack (a flat fissure must not pop like a prop)
			_outline_frame(img, c * cw, ch, Color.html("#1c2418"), cw, ch)
	return img

## Foliage-cell fill: like _fill but clamped to the 16x24 foliage cell, not the
## (now larger) character frame — a spill would bleed into the neighbour cell.
func _ffill(img: Image, ox: int, lx: int, ly: int, w: int, h: int, col: Color, oy: int = 0) -> void:
	CharPainterScript.fill(img, ox, oy, lx, ly, w, h, col, FOLIAGE_CELL_W, FOLIAGE_CELL_H)

func _tree(img: Image, ox: int, style: String) -> void:
	var trunk := Color.html("#5a3f26")
	var leaf := Color.html("#4a7a3a")
	var leaf_hi := Color.html("#6aa050")
	var leaf_sh := Color.html("#2f5528")
	_ffill(img, ox, 7, 15, 2, 8, trunk)   # trunk, rooted at the bottom
	match style:
		"tall":
			_ffill(img, ox, 6, 2, 4, 12, leaf)
			_ffill(img, ox, 5, 4, 6, 9, leaf)
			_ffill(img, ox, 6, 2, 2, 12, leaf_hi)
			_ffill(img, ox, 9, 5, 2, 8, leaf_sh)
		"bushy":
			_ffill(img, ox, 2, 6, 12, 8, leaf)
			_ffill(img, ox, 4, 3, 8, 4, leaf)
			_ffill(img, ox, 3, 4, 3, 7, leaf_hi)
			_ffill(img, ox, 10, 8, 4, 5, leaf_sh)
		_:
			_ffill(img, ox, 3, 3, 10, 10, leaf)
			_ffill(img, ox, 4, 2, 8, 2, leaf)
			_ffill(img, ox, 3, 3, 4, 4, leaf_hi)
			_ffill(img, ox, 9, 9, 4, 4, leaf_sh)

func _grass(img: Image, ox: int) -> void:
	var blade := Color.html("#5f9a45")
	var blade_hi := Color.html("#7fbf5a")
	_ffill(img, ox, 6, 15, 1, 8, blade)
	_ffill(img, ox, 8, 13, 1, 10, blade_hi)
	_ffill(img, ox, 10, 16, 1, 7, blade)
	_ffill(img, ox, 7, 17, 1, 6, blade_hi)
	_ffill(img, ox, 9, 15, 1, 8, blade)

func _rock(img: Image, ox: int, big: bool) -> void:
	var stone := Color.html("#8a8a92")
	var stone_hi := Color.html("#a8a8b0")
	var stone_sh := Color.html("#5c5c66")
	if big:
		_ffill(img, ox, 3, 14, 10, 8, stone)
		_ffill(img, ox, 4, 13, 7, 2, stone)
		_ffill(img, ox, 4, 14, 4, 2, stone_hi)
		_ffill(img, ox, 9, 18, 4, 3, stone_sh)
	else:
		_ffill(img, ox, 5, 17, 6, 5, stone)
		_ffill(img, ox, 6, 17, 2, 2, stone_hi)
		_ffill(img, ox, 8, 20, 3, 2, stone_sh)

# --- ground decals (foliage.png row 1) -----------------------------------------
func _flower(img: Image, ox: int, oy: int, petal: Color) -> void:
	var stem := Color.html("#3f6f30")
	_ffill(img, ox, 7, 18, 1, 4, stem, oy)
	_ffill(img, ox, 9, 20, 1, 2, stem, oy)         # side blade
	_ffill(img, ox, 6, 15, 3, 3, petal, oy)
	_ffill(img, ox, 7, 16, 1, 1, Color.html("#fff4d0"), oy)  # bright center
	_ffill(img, ox, 10, 17, 2, 2, petal, oy)       # smaller second bloom
	_ffill(img, ox, 10, 19, 1, 2, stem, oy)

func _pebbles(img: Image, ox: int, oy: int) -> void:
	var stone := Color.html("#8a8a92")
	var stone_hi := Color.html("#a8a8b0")
	var stone_sh := Color.html("#5c5c66")
	_ffill(img, ox, 3, 19, 3, 3, stone, oy)
	_ffill(img, ox, 3, 19, 2, 1, stone_hi, oy)
	_ffill(img, ox, 8, 17, 4, 4, stone, oy)
	_ffill(img, ox, 8, 17, 2, 2, stone_hi, oy)
	_ffill(img, ox, 10, 20, 2, 1, stone_sh, oy)
	_ffill(img, ox, 12, 21, 2, 2, stone, oy)

func _crack_decal(img: Image, ox: int, oy: int) -> void:
	var dark := Color.html("#20242a")
	var mid := Color.html("#3a3f48")
	_ffill(img, ox, 3, 16, 2, 1, mid, oy)
	_ffill(img, ox, 4, 17, 2, 1, dark, oy)
	_ffill(img, ox, 5, 18, 3, 1, dark, oy)
	_ffill(img, ox, 7, 19, 2, 1, dark, oy)
	_ffill(img, ox, 8, 20, 3, 1, dark, oy)
	_ffill(img, ox, 10, 21, 2, 1, mid, oy)
	_ffill(img, ox, 6, 17, 1, 1, mid, oy)          # fork
	_ffill(img, ox, 9, 18, 2, 1, mid, oy)

func _stump(img: Image, ox: int, oy: int) -> void:
	var wood := Color.html("#7a5230")
	var wood_hi := Color.html("#9a6b40")
	var ring := Color.html("#5a3c22")
	_ffill(img, ox, 4, 16, 8, 6, wood, oy)         # trunk block
	_ffill(img, ox, 4, 14, 8, 3, wood_hi, oy)      # cut top
	_ffill(img, ox, 6, 15, 4, 1, ring, oy)         # growth ring
	_ffill(img, ox, 7, 15, 2, 1, wood_hi, oy)
	_ffill(img, ox, 3, 20, 2, 2, wood, oy)         # root flare
	_ffill(img, ox, 11, 20, 2, 2, wood, oy)

func _bush(img: Image, ox: int, oy: int) -> void:
	var leaf := Color.html("#4a7a3a")
	var leaf_hi := Color.html("#6aa050")
	var leaf_sh := Color.html("#2f5528")
	_ffill(img, ox, 3, 15, 10, 7, leaf, oy)
	_ffill(img, ox, 5, 13, 6, 3, leaf, oy)
	_ffill(img, ox, 5, 14, 3, 3, leaf_hi, oy)
	_ffill(img, ox, 9, 19, 4, 3, leaf_sh, oy)
