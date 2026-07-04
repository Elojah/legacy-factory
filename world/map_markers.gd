class_name MapMarkers extends Node2D
## Draws village markers (player spawn points), merchant stalls, waypoint
## obelisks, resource orbs, shrine monoliths and (deliberately faint) secret
## cache glints from the lobby geometry. It is a CHILD of TestMap ordered AFTER
## the TileMapLayers, so it renders ON TOP of the floor tiles (a parent's own
## _draw would render under its children). Cosmetic only — every INTERACTION
## (shop/travel range, pickups, shrines) is validated server-side against the
## same geometry points.

## Danger-tier tints (orbs, shrine glow): the risk/reward gradient must read at
## a glance — cool at the safe rim, hot toward the center.
const TIER_COLORS: Array[Color] = [
	Color(0.25, 0.80, 1.00),   # tier 0: cyan
	Color(0.35, 0.95, 0.55),   # tier 1: green
	Color(1.00, 0.80, 0.25),   # tier 2: gold
	Color(1.00, 0.40, 0.55),   # tier 3: rose (the apex ring)
]

var _geometry: WorldGeometry
# Taken pickups (hidden until the server's orb_event says they respawned).
var _taken_orbs: Dictionary = {}
var _taken_caches: Dictionary = {}

func setup(geometry: WorldGeometry) -> void:
	_geometry = geometry
	_taken_orbs.clear()
	_taken_caches.clear()
	queue_redraw()

## Reliable pickup-state mirror (kind 0 = orb, 1 = cache), fed by ClientWorld
## from the orb_event RPC.
func set_pickup_taken(kind: int, index: int, taken: bool) -> void:
	var d := _taken_orbs if kind == 0 else _taken_caches
	if taken:
		d[index] = true
	else:
		d.erase(index)
	queue_redraw()

func _draw() -> void:
	if _geometry == null:
		return
	for i in _geometry.villages.size():
		var f: int = _geometry.village_factions[i] if i < _geometry.village_factions.size() else 0
		_draw_hut(_geometry.villages[i], f)
		_draw_waypoint(_geometry.villages[i] + Vector2(12, 2))
	for p in _geometry.merchants:
		_draw_merchant(p)
		_draw_waypoint(p + Vector2(-14, 2))
	for i in _geometry.resources.size():
		if not _taken_orbs.has(i):
			var t: int = _geometry.resource_tiers[i] if i < _geometry.resource_tiers.size() else 0
			_draw_orb(_geometry.resources[i], t)
	for i in _geometry.caches.size():
		if not _taken_caches.has(i):
			_draw_cache_glint(_geometry.caches[i])
	# Shrines: the same pure derivation as Lobby._init — field islands (>= 5,
	# non-boss) of tier >= 1, one monolith at the island rect center.
	for i in range(5, _geometry.islands.size()):
		if i in _geometry.boss_islands or _geometry.island_tiers[i] < 1:
			continue
		_draw_shrine(_geometry.islands[i].get_center(), _geometry.island_tiers[i])
	for i in _geometry.boss_spawns.size():
		_draw_boss_banner(_geometry.boss_spawns[i], _geometry.boss_kits[i])

## A tiny hut: walls + door + gabled roof, centered on the spawn point. The roof
## takes the owning faction's colour (corner start villages) so each home corner
## reads at a glance; faction 0 keeps the neutral clay red.
func _draw_hut(p: Vector2, faction: int) -> void:
	draw_rect(Rect2(p + Vector2(-6, -2), Vector2(12, 8)), Color(0.62, 0.43, 0.27))      # walls
	draw_rect(Rect2(p + Vector2(-2, 1), Vector2(4, 5)), Color(0.28, 0.18, 0.11))        # door
	var roof := PackedVector2Array([p + Vector2(-8, -2), p + Vector2(0, -9), p + Vector2(8, -2)])
	# draw_primitive emits the triangle directly; draw_colored_polygon's triangulator
	# rejects such a tiny shape at the huge island coordinates ("triangulation failed").
	var roof_col := Color(0.58, 0.28, 0.22)
	if faction > 0:
		roof_col = FactionPalette.color_for(faction).lerp(roof_col, 0.35)
	draw_primitive(roof, PackedColorArray([roof_col, roof_col, roof_col]), PackedVector2Array())  # roof
	draw_polyline(roof, Color(0.24, 0.12, 0.10), 1.0)                                   # roof outline

## A merchant stall (the gem shop): counter, striped awning on poles, and a
## hanging gem sign — visually distinct from the plain village huts.
func _draw_merchant(p: Vector2) -> void:
	draw_line(p + Vector2(-8, 3), p + Vector2(-8, -10), Color(0.42, 0.30, 0.20), 1.5)  # poles
	draw_line(p + Vector2(8, 3), p + Vector2(8, -10), Color(0.42, 0.30, 0.20), 1.5)
	draw_rect(Rect2(p + Vector2(-8, -2), Vector2(16, 5)), Color(0.55, 0.38, 0.24))     # counter
	draw_rect(Rect2(p + Vector2(-8, -2), Vector2(16, 2)), Color(0.68, 0.50, 0.32))     # top board
	for i in 4:                                                                        # striped awning
		var col := Color(0.85, 0.30, 0.28) if i % 2 == 0 else Color(0.92, 0.88, 0.80)
		draw_rect(Rect2(p + Vector2(-10 + i * 5, -14), Vector2(5, 4)), col)
	# Gem sign under the awning. draw_primitive: the polygon triangulator rejects
	# tiny shapes at huge island coordinates (same note as the hut roof).
	var gem := PackedVector2Array([p + Vector2(0, -9), p + Vector2(3, -6), p + Vector2(0, -3), p + Vector2(-3, -6)])
	var gcol := Color(0.45, 0.95, 0.85)
	draw_primitive(gem, PackedColorArray([gcol, gcol, gcol, gcol]), PackedVector2Array())

## A kit-tinted war banner marking a boss arena (drawn at the boss home point).
func _draw_boss_banner(p: Vector2, kit: int) -> void:
	var col := BossPalette.color_for(kit)
	draw_line(p + Vector2(0, 4), p + Vector2(0, -14), Color(0.35, 0.25, 0.18), 2.0)  # pole
	var flag := PackedVector2Array([p + Vector2(0, -14), p + Vector2(12, -10), p + Vector2(0, -6)])
	# draw_primitive: the polygon triangulator rejects tiny shapes at huge coords.
	draw_primitive(flag, PackedColorArray([col, col, col]), PackedVector2Array())
	draw_polyline(flag, Color(0.2, 0.12, 0.08), 1.0)
	draw_circle(p + Vector2(0, 4), 3.0, Color(0.2, 0.15, 0.1))                       # base

## A glowing resource orb, tier-tinted (and slightly larger deeper in) so the
## deeper-is-richer gradient reads from across a bridge.
func _draw_orb(p: Vector2, tier: int) -> void:
	var col: Color = TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]
	var halo := 6.0 + float(tier)
	draw_circle(p, halo, Color(col.r, col.g, col.b, 0.25))        # halo
	draw_circle(p, 3.5, col)                                      # core
	draw_circle(p + Vector2(-1, -1), 1.0, Color(0.92, 1.0, 1.0))  # highlight

## A secret cache: a faint sparkle only — no stall, no banner, nothing on any
## map. Discovery is walking the shortcut bridges and noticing the glint.
func _draw_cache_glint(p: Vector2) -> void:
	draw_line(p + Vector2(-3, 0), p + Vector2(3, 0), Color(1.0, 0.95, 0.7, 0.35), 1.0)
	draw_line(p + Vector2(0, -3), p + Vector2(0, 3), Color(1.0, 0.95, 0.7, 0.35), 1.0)
	draw_circle(p, 1.2, Color(1.0, 0.98, 0.85, 0.55))

## A waypoint obelisk beside each village hut / merchant stall: the landmark for
## the travel network (press T within WAYPOINT_RANGE of the anchor).
func _draw_waypoint(p: Vector2) -> void:
	draw_rect(Rect2(p + Vector2(-2, -10), Vector2(4, 12)), Color(0.45, 0.48, 0.62))  # standing stone
	draw_rect(Rect2(p + Vector2(-3, 1), Vector2(6, 2)), Color(0.35, 0.37, 0.48))     # base
	var tip := PackedVector2Array([p + Vector2(-2, -10), p + Vector2(0, -14), p + Vector2(2, -10)])
	var tcol := Color(0.55, 0.60, 0.78)
	# draw_primitive: the polygon triangulator rejects tiny shapes at huge coords.
	draw_primitive(tip, PackedColorArray([tcol, tcol, tcol]), PackedVector2Array())
	draw_circle(p + Vector2(0, -6), 1.4, Color(0.55, 0.9, 1.0, 0.9))                 # rune glow

## A shrine monolith on each dangerous field island (the co-op capture point):
## stone ring + standing stone, glow tinted by the island's danger tier.
func _draw_shrine(p: Vector2, tier: int) -> void:
	var col: Color = TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]
	for k in 6:                                                     # stone ring
		var off := Vector2.RIGHT.rotated(TAU * float(k) / 6.0) * 14.0
		draw_circle(p + off, 2.2, Color(0.42, 0.44, 0.52))
	draw_rect(Rect2(p + Vector2(-3, -16), Vector2(6, 18)), Color(0.48, 0.50, 0.60))  # monolith
	draw_rect(Rect2(p + Vector2(-5, 0), Vector2(10, 3)), Color(0.36, 0.38, 0.46))    # base
	draw_circle(p + Vector2(0, -10), 2.6, Color(col.r, col.g, col.b, 0.9))           # tier sigil
	draw_circle(p + Vector2(0, -10), 5.0, Color(col.r, col.g, col.b, 0.22))          # sigil halo
