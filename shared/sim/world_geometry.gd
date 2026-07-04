class_name WorldGeometry extends RefCounted
## The collision world used by the SIMULATION. The sim resolves against these
## numbers — NOT the visual TileMap — so collision is byte-identical on client
## and server. The active geometry is an INSTANCE built per lobby from a seed by
## WorldGenerator; both ends build the same instance and pass it into
## WorldSim.step, so prediction and authority stay numerically identical.
##
## Walkable space is the union of axis-aligned rects (islands ++ bridges); outside
## the union is water (impassable). `resolve_circle` keeps the player disk inside
## that union. This is correct and gap-free ONLY because the generator guarantees
## every connected island/bridge pair overlaps by > 2*ENTITY_RADIUS in BOTH axes
## (see world_generator.gd) — otherwise the r-insets would leave a dead seam.

var bounds: Rect2 = Rect2()              # union AABB (+pad): camera limits / water rect
var walkable: Array[Rect2] = []          # islands ++ bridges, FIXED order = collision union
var islands: Array[Rect2] = []
var island_biomes: Array[int] = []       # parallel to islands
var island_tiers: Array[int] = []        # parallel: danger tier 0..3 (corners 0, center 3)
var island_factions: Array[int] = []     # parallel: 0 neutral, 1..4 = faction corner start
var bridges: Array[Rect2] = []
var bridge_biomes: Array[int] = []       # parallel to bridges (= parent island's biome)
var villages: Array[Vector2] = []        # player spawn points (world coords, corner islands)
var village_factions: Array[int] = []    # parallel to villages: owning faction 1..4
var merchants: Array[Vector2] = []       # corner islands + a few mid-ring; shop range checks
var resources: Array[Vector2] = []       # orb positions (gem pickups; taken state is server-only)
var resource_tiers: Array[int] = []      # parallel: hosting island's danger tier (gem award)
var caches: Array[Vector2] = []          # secret caches: midpoints of the extra shortcut bridges
var cache_tiers: Array[int] = []         # parallel: max tier of the two bridged islands
var monster_spawns: Array[Vector2] = []  # field islands only
var monster_tiers: Array[int] = []       # parallel: hosting island's danger tier
var boss_islands: Array[int] = []        # island indices hosting a boss (never a corner)
var boss_spawns: Array[Vector2] = []     # boss home positions, parallel to boss_islands
var boss_kits: Array[int] = []           # BossDefs.KIT_*, parallel (from island biome)
var boss_tiers: Array[int] = []          # parallel: danger tier (drives hp + gem award)

## Owning faction of a merchant BY INDEX — a pure law of the generator's append
## order: the corner branch of the island loop (i < 4) runs first, so merchants
## 0-3 are the corner shops of factions 1-4; every later index is a neutral mid
## merchant. Shared so client UI and server validation agree byte-for-byte.
func merchant_faction(index: int) -> int:
	return index + 1 if index < 4 else 0

## Keep a circle of `radius` inside the walkable union. Pure function of the
## instance data (fixed `walkable` order, strict-index tie-break) so it replays
## identically during reconciliation.
func resolve_circle(pos: Vector2, radius: float) -> Vector2:
	# 1) Supported: the disk already fits inside some single rect's r-inset → keep.
	for rect in walkable:
		if pos.x >= rect.position.x + radius and pos.x <= rect.position.x + rect.size.x - radius \
		and pos.y >= rect.position.y + radius and pos.y <= rect.position.y + rect.size.y - radius:
			return pos
	# 2) Over water: project onto the NEAREST rect's r-inset.
	var best := pos
	var best_d2 := INF
	for rect in walkable:
		var q := Vector2(
			clampf(pos.x, rect.position.x + radius, rect.position.x + rect.size.x - radius),
			clampf(pos.y, rect.position.y + radius, rect.position.y + rect.size.y - radius))
		var d2 := pos.distance_squared_to(q)
		if d2 < best_d2:           # strict < keeps the lowest index on ties (deterministic)
			best_d2 = d2
			best = q
	return best

## Stable fold of the geometry (integer coords only) for cross-end determinism
## checks: the server (on build) and client (after generate) must print the same
## value for the same seed. 64-bit wrap is deterministic.
func debug_hash() -> int:
	var h: int = 0
	for rect in walkable:
		h = h * 1000003 + int(rect.position.x)
		h = h * 1000003 + int(rect.position.y)
		h = h * 1000003 + int(rect.size.x)
		h = h * 1000003 + int(rect.size.y)
	for v in villages:
		h = h * 1000003 + int(v.x)
		h = h * 1000003 + int(v.y)
	for v in merchants:
		h = h * 1000003 + int(v.x)
		h = h * 1000003 + int(v.y)
	for v in resources:
		h = h * 1000003 + int(v.x)
		h = h * 1000003 + int(v.y)
	for v in caches:
		h = h * 1000003 + int(v.x)
		h = h * 1000003 + int(v.y)
	for v in monster_spawns:
		h = h * 1000003 + int(v.x)
		h = h * 1000003 + int(v.y)
	for i in boss_spawns.size():
		h = h * 1000003 + int(boss_spawns[i].x)
		h = h * 1000003 + int(boss_spawns[i].y)
		h = h * 1000003 + boss_kits[i]
	# Metadata folds (fixed order): biomes were historically unhashed; the tier /
	# faction arrays drive spawning on both ends, so a divergence must be loud.
	for b in island_biomes:
		h = h * 1000003 + b
	for t in island_tiers:
		h = h * 1000003 + t
	for f in island_factions:
		h = h * 1000003 + f
	for f in village_factions:
		h = h * 1000003 + f
	for t in monster_tiers:
		h = h * 1000003 + t
	for t in boss_tiers:
		h = h * 1000003 + t
	for t in resource_tiers:
		h = h * 1000003 + t
	for t in cache_tiers:
		h = h * 1000003 + t
	return h
