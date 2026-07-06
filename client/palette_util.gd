class_name PaletteUtil extends RefCounted
## Hue-shifted color-ramp generator: the one source of shading tones for all
## code-baked art. Shadows shift toward cool blue and gain saturation; highlights
## shift toward warm amber and lose a little — the classic pixel-art recipe that
## keeps ramps vibrant instead of muddy grey.
##
## Pure static color math — no nodes, no randomness, no autoload references:
## this file is preload()ed by tools/art_baker.gd and so sits in the --script
## tools compile graph (same analyzer rules as client/char_painter.gd).

const HUE_COOL := 0.66  # shadows drift toward this hue (blue)
const HUE_WARM := 0.10  # highlights drift toward this hue (amber)

## One tone `k` steps away from `base` (k < 0 = darker/cooler, k > 0 = lighter/warmer).
static func shade(base: Color, k: float) -> Color:
	if is_zero_approx(k):
		return base
	var h: float = base.h
	var s: float = base.s
	var v: float = base.v
	if k > 0.0:
		v = clampf(v + 0.14 * k, 0.0, 1.0)
		s = clampf(s - 0.05 * k, 0.0, 1.0)
		h = _hue_toward(h, HUE_WARM, 0.08 * k)
	else:
		var d: float = -k
		v = clampf(v - 0.16 * d, 0.0, 1.0)
		s = clampf(s + 0.06 * d, 0.0, 1.0)
		h = _hue_toward(h, HUE_COOL, 0.10 * d)
	return Color.from_hsv(h, s, v, base.a)

## A full ramp around `base`, darkest first; `base` sits at the middle index
## (ramp(base, 5) = [-2, -1, base, +1, +2] steps).
static func ramp(base: Color, steps: int = 5) -> Array[Color]:
	var tones: Array[Color] = []
	var mid: int = steps >> 1
	for i in steps:
		tones.append(shade(base, float(i - mid)))
	return tones

## Outline tone for sprites painted from `base`: very dark but hue-tinted,
## never flat black.
static func outline_for(base: Color) -> Color:
	return shade(base, -2.0).lerp(Color(0.08, 0.08, 0.13), 0.5)

## Shortest-path hue drift: move `h` a fraction `f` of the way toward `target`
## around the hue circle.
static func _hue_toward(h: float, target: float, f: float) -> float:
	var d: float = fposmod(target - h + 0.5, 1.0) - 0.5
	return fposmod(h + d * f, 1.0)
