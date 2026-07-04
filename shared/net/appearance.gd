class_name Appearance extends RefCounted
## Compact character-appearance spec: class + hair style/color + skin tone packed
## into one u16 that rides in EntityState (and the ready_in_lobby handshake).
## This is index data only — part of the wire contract the server validates.
## The actual Colors live client-side in CharPainter; display names in the UI.
##
## Bit layout (low to high):  [0-1] char_class  [2-4] hair_style
## [5-7] hair_color  [8-9] skin_tone  [10-15] reserved (must be 0).
## DEFAULT = 0 reproduces the original player.png look exactly (warrior /
## short brown hair / default skin), so monsters and un-customized players
## need no special-casing.
##
## No autoload or Color references here: the headless tools path
## (gen_art -> art_baker -> char_painter) preload()s this with no project scan.

const CLASS_WARRIOR := 0
const CLASS_MAGE := 1
const CLASS_ARCHER := 2
const CLASS_COUNT := 3

const HAIR_SHORT := 0
const HAIR_LONG := 1
const HAIR_SPIKY := 2
const HAIR_BALD := 3
const HAIR_STYLE_COUNT := 4

const HAIR_COLOR_COUNT := 6  # brown / black / blonde / red / white / blue
const SKIN_TONE_COUNT := 4   # default / tan / dark / pale

const DEFAULT := 0

static func encode(char_class: int, hair_style: int, hair_color: int, skin_tone: int) -> int:
	return (char_class & 0x3) | ((hair_style & 0x7) << 2) | ((hair_color & 0x7) << 5) | ((skin_tone & 0x3) << 8)

static func char_class_of(a: int) -> int:
	return a & 0x3

static func hair_style_of(a: int) -> int:
	return (a >> 2) & 0x7

static func hair_color_of(a: int) -> int:
	return (a >> 5) & 0x7

static func skin_tone_of(a: int) -> int:
	return (a >> 8) & 0x3

## Clamp every subfield into its valid range and zero the reserved bits.
## The server runs this on every incoming value (never trust the client);
## the client runs it on values loaded from disk.
static func sanitize(a: int) -> int:
	return encode(
		clampi(char_class_of(a), 0, CLASS_COUNT - 1),
		clampi(hair_style_of(a), 0, HAIR_STYLE_COUNT - 1),
		clampi(hair_color_of(a), 0, HAIR_COLOR_COUNT - 1),
		clampi(skin_tone_of(a), 0, SKIN_TONE_COUNT - 1))
