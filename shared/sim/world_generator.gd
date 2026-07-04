class_name WorldGenerator
## Deterministic procedural island-map generator. The SAME (seed, size_preset)
## produces a byte-identical WorldGeometry on client and server — that is the
## determinism contract for the islands map.
##
## All layout math is done in INTEGER TILE units and multiplied by TILE_SIZE only
## at the very end, so coordinates are exact in float32 (16 * int) and identical
## across platforms. Randomness comes solely from a seeded RandomNumberGenerator
## (never the global RNG / Array.shuffle(), which are not deterministic here).
##
## Map shape: an odd square grid of small sky-islands. The FOUR CORNERS are the
## faction start islands (villages + merchant, no monsters); the CENTER island is
## the apex boss arena; danger rises toward the center (per-island tier 0..3 from
## the Chebyshev ring distance to the center cell). Islands are connected by a
## spanning tree of bridges plus a few extra shortcut edges, each bridge a dog-leg
## with varied width/turns. Every connected island/bridge seam overlaps by >= 2
## tiles in both axes so the union collision in WorldGeometry.resolve_circle never
## traps a player (see lemma there).

const TS := BiomeRegistry.TILE_SIZE   # 16 px/tile (matches the renderer)

# Size presets (index also used as the lobby "size"): scale player cap + map.
const SIZE_SMALL := 0
const SIZE_MEDIUM := 1
const SIZE_LARGE := 2

# cols/rows are ODD so a true center cell exists; cols*rows must be >= islands.
# players = max players / spawn target. bosses = boss arenas (center first, then
# innermost fill islands); extra_bridges = shortcut edges beyond the spanning
# tree; mid_merchants = neutral shops on the fill islands nearest the center.
# LARGE is the raid map — its 20-player cap is what the apex boss is tuned to
# require.
const PRESETS := {
	SIZE_SMALL:  {"cols": 5, "rows": 5, "islands": 9, "players": 2, "res": 2, "mon": 1, "bosses": 2, "extra_bridges": 2, "mid_merchants": 1},
	SIZE_MEDIUM: {"cols": 7, "rows": 7, "islands": 14, "players": 4, "res": 2, "mon": 2, "bosses": 3, "extra_bridges": 4, "mid_merchants": 2},
	SIZE_LARGE:  {"cols": 9, "rows": 9, "islands": 22, "players": 20, "res": 3, "mon": 2, "bosses": 5, "extra_bridges": 6, "mid_merchants": 3},
}

# Layout tuning, in TILES. Islands are now SMALL — a village or one boss arena
# each (~3-7 s to cross at PLAYER_SPEED 140 px/s: 24 tiles = 384 px ≈ 2.7 s,
# 64 tiles = 1024 px ≈ 7.3 s). Size range depends on the island's ROLE:
const ISLAND_MIN := 24    # global min island edge (== FIELD_MIN)
const ISLAND_MAX := 64    # global max island edge; must be <= CELL - 2*MARGIN
const CORNER_MIN := 40    # faction start islands: room for villages + merchant
const CORNER_MAX := 64
const ARENA_MIN := 44     # boss islands: room for the fight (boss radius 28 px)
const ARENA_MAX := 64
const FIELD_MIN := 24     # everything else
const FIELD_MAX := 48
const MARGIN := 24        # tiles between an island and its cell border; the sky gap
                          # between islands in adjacent cells is >= 2*MARGIN (768 px)
# Grid cell edge. INVARIANT: CELL >= ISLAND_MAX + 2*MARGIN (64 + 48 = 112), so an
# island always fits with its margins and distinct cells never overlap. The slack
# becomes placement jitter (0 at max island size, up to 40 tiles at FIELD_MIN).
const CELL := 112
const BORDER := 4          # inset (tiles) for placing spawns/resources off the shoreline
const BRIDGE_W_MIN := 4    # narrowest bridge (64 px catwalk); even, >= 2*radius
const BRIDGE_W_MAX := 12   # widest bridge (192 px; always < island min dim - 2)
const MAX_TIER := 3        # danger tiers 0..3 (rides EntityState.upgrades bits 0-1)
const JOG_SNAP := 15       # jog_pct < 15 -> 0 / > 85 -> 100: the dog-leg collapses
                           # into an L-turn (arm at that end degenerates into overlap)

## Build the geometry for a lobby. `seed` is the lobby seed; `size_preset` one of
## SIZE_SMALL/MEDIUM/LARGE.
static func generate(seed: int, size_preset: int) -> WorldGeometry:
	var cfg: Dictionary = PRESETS.get(size_preset, PRESETS[SIZE_MEDIUM])
	# Explicit type (never :=) and prewarmed at boot — see the 4.7 native-.new() note.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed

	var cols: int = int(cfg["cols"])
	var rows: int = int(cfg["rows"])

	# 1) Cells & roles. Island INDEX encodes role: 0-3 = the four corner cells
	#    (faction 1-4 in fixed NW/NE/SW/SE order), 4 = the center cell (apex boss),
	#    5+ = shuffled fill cells. rng budget: exactly (free cells - 1) shuffle draws.
	var corner_cells: Array = [
		Vector2i(0, 0), Vector2i(cols - 1, 0),
		Vector2i(0, rows - 1), Vector2i(cols - 1, rows - 1),
	]
	var center_cell := Vector2i(cols / 2, rows / 2)
	var free_cells: Array = []
	for cy in rows:
		for cx in cols:
			var c := Vector2i(cx, cy)
			if c == center_cell or corner_cells.has(c):
				continue
			free_cells.append(c)
	_shuffle(free_cells, rng)
	var n_islands: int = clampi(int(cfg["islands"]), 5, 5 + free_cells.size())
	var cells: Array = []
	cells.append_array(corner_cells)
	cells.append(center_cell)
	for i in n_islands - 5:
		cells.append(free_cells[i])
	var n_cells: int = cells.size()

	# Danger tier per island: Chebyshev ring distance to the center cell, mapped
	# to 0..MAX_TIER with integer math. Corners are always 0, the center always
	# MAX_TIER, monotone in between. Pure function of the cells — NO rng draws.
	var max_ring: int = maxi(1, maxi(cols / 2, rows / 2))
	var rings: Array = []
	var tiers: Array = []
	for i in n_cells:
		var cell: Vector2i = cells[i]
		var ring: int = maxi(absi(cell.x - center_cell.x), absi(cell.y - center_cell.y))
		rings.append(ring)
		tiers.append(_tier_for_ring(ring, max_ring))

	# 2) Boss promotion: the center is always a boss (when the preset has any);
	#    the rest are the fill islands nearest the center — sort by [ring, index]
	#    (integer keys, index tie-break). Corners are never candidates. NO rng draws.
	var n_bosses: int = mini(int(cfg.get("bosses", 0)), n_cells - 4)
	var boss_set := {}
	if n_bosses > 0:
		boss_set[4] = true
		var order: Array = []
		for i in range(5, n_cells):
			order.append([rings[i], i])
		order.sort()
		for k in mini(n_bosses - 1, order.size()):
			boss_set[order[k][1]] = true

	# 3) Island rects (tiles) + biomes. rng budget: the biome pool, then exactly
	#    4 draws per island (w, h, jx, jy) — the ROLE only changes the randi_range
	#    BOUNDS, never the draw count, and role is a pure function of index/cells.
	var isl: Array = []                 # Array[Rect2i]
	var biomes := _biome_pool(n_cells, rng)
	for i in n_cells:
		var cell: Vector2i = cells[i]
		var lo := FIELD_MIN
		var hi := FIELD_MAX
		if i < 4:
			lo = CORNER_MIN
			hi = CORNER_MAX
		elif boss_set.has(i):
			lo = ARENA_MIN
			hi = ARENA_MAX
		var w: int = rng.randi_range(lo, hi)
		var h: int = rng.randi_range(lo, hi)
		var jx: int = rng.randi_range(0, maxi(0, CELL - w - 2 * MARGIN))
		var jy: int = rng.randi_range(0, maxi(0, CELL - h - 2 * MARGIN))
		var x: int = cell.x * CELL + MARGIN + jx
		var y: int = cell.y * CELL + MARGIN + jy
		isl.append(Rect2i(x, y, w, h))

	# 4) Bridges. First a spanning tree (Prim) over island centers using INTEGER
	#    squared distance (zero float ambiguity), then `extra_bridges` shortcut
	#    edges (shortest non-tree pairs, sorted [d2, a, b]) so the center is
	#    reachable by multiple routes. rng budget: a FIXED 2 calls per edge
	#    (bw, then jog_pct), drawn unconditionally, tree edges first then extras
	#    in sorted-candidate order.
	var bridges_t: Array = []           # Array[Rect2i]
	var bridge_parent: Array = []       # parallel: parent island index (for biome)
	var caches: Array = []              # secret cache points (world coords), shortcut bridges only
	var cache_tiers: Array = []         # parallel: max tier of the two bridged islands
	var centers: Array = []
	for r in isl:
		centers.append(Vector2i(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2))
	var tree_pairs := {}                # Vector2i(min, max) -> true
	if n_cells > 1:
		var in_tree: Array = [0]
		var remaining: Array = []
		for i in range(1, n_cells):
			remaining.append(i)
		while not remaining.is_empty():
			var best_a := -1
			var best_b := -1
			var best_d := -1
			for a in in_tree:
				for b in remaining:
					var dx: int = centers[a].x - centers[b].x
					var dy: int = centers[a].y - centers[b].y
					var d: int = dx * dx + dy * dy
					if best_d < 0 or d < best_d:
						best_d = d
						best_a = a
						best_b = b
			_append_bridge(bridges_t, bridge_parent, isl, best_a, best_b, rng)
			tree_pairs[Vector2i(mini(best_a, best_b), maxi(best_a, best_b))] = true
			in_tree.append(best_b)
			remaining.erase(best_b)
		# Shortcut edges: all non-tree pairs sorted by [d2, a, b] (integer keys,
		# lowest-index tie-break), take the first K. Connectivity only improves.
		var extra: int = int(cfg.get("extra_bridges", 0))
		if extra > 0:
			var cands: Array = []
			for a in n_cells:
				for b in range(a + 1, n_cells):
					if tree_pairs.has(Vector2i(a, b)):
						continue
					var dx2: int = centers[a].x - centers[b].x
					var dy2: int = centers[a].y - centers[b].y
					cands.append([dx2 * dx2 + dy2 * dy2, a, b])
			cands.sort()
			for k in mini(extra, cands.size()):
				_append_bridge(bridges_t, bridge_parent, isl, cands[k][1], cands[k][2], rng)
				# Secret cache on the middle segment of each SHORTCUT bridge — a
				# pure derivation of the just-appended rects (ZERO rng draws, the
				# stream shape is untouched). Rewards route knowledge: shortcuts
				# are the paths a player only crosses when exploring off the tree.
				var mid: Rect2i = bridges_t[bridges_t.size() - 2]
				@warning_ignore("integer_division")
				var mid_tile := Vector2i(mid.position.x + mid.size.x / 2, mid.position.y + mid.size.y / 2)
				caches.append(_tile_center(mid_tile))
				cache_tiers.append(maxi(tiers[cands[k][1]], tiers[cands[k][2]]))

	# 5) Spawns / resources / merchants: draw a FIXED number of distinct interior
	#    tiles per island — the SAME total for every island regardless of role
	#    (the stream shape is load-bearing) — then keep/discard by role using
	#    fixed slot offsets:
	#      [0 .. vill_per)                      village slots (corners only)
	#      [res_off .. res_off+res+MAX_TIER)    resource slots (res kept, +tier on field)
	#      [mon_off .. mon_off+mon+MAX_TIER)    monster slots (field only, mon+tier kept)
	#      [total_k - 1]                        mid-merchant anchor (chosen fill islands)
	var vill_per := ceili(float(cfg["players"]) / 4.0)   # villages per corner island
	var res_base: int = int(cfg["res"])
	var mon_base: int = int(cfg["mon"])
	var res_off := vill_per
	var mon_off := res_off + res_base + MAX_TIER
	var total_k := mon_off + mon_base + MAX_TIER + 1
	# Mid-map merchants: the fill islands nearest the center (non-boss), sorted
	# [ring, index] — a pure function, NO rng draws.
	var mid_set := {}
	var mid_n: int = int(cfg.get("mid_merchants", 0))
	if mid_n > 0:
		var mm: Array = []
		for i in range(5, n_cells):
			if boss_set.has(i):
				continue
			mm.append([rings[i], i])
		mm.sort()
		for k in mini(mid_n, mm.size()):
			mid_set[mm[k][1]] = true

	var villages: Array = []
	var village_factions: Array = []
	var merchants: Array = []
	var resources: Array = []
	var resource_tiers: Array = []      # parallel: hosting island's danger tier
	var monster_spawns: Array = []
	var monster_tiers: Array = []
	var boss_islands: Array = []
	var boss_spawns: Array = []
	var boss_tiers: Array = []
	for i in n_cells:
		var pts := _sample_interior(isl[i], BORDER, total_k, rng)
		var tier: int = tiers[i]
		if i < 4:
			# Corner = faction (i+1) home: villages + merchant + orbs, NO monsters.
			for v in vill_per:
				# One merchant per corner island, pinned 3 tiles east of the
				# island's first village: a pure function of already-drawn data —
				# NO rng draws. Villages are inset BORDER (4) tiles from the
				# shoreline, so +3 tiles stays walkable.
				if v == 0:
					merchants.append(pts[v] + Vector2(float(3 * TS), 0.0))
				villages.append(pts[v])
				village_factions.append(i + 1)
			for v in res_base:
				resources.append(pts[res_off + v])
				resource_tiers.append(tier)
		elif boss_set.has(i):
			# Boss arena: orbs stay (cosmetic), villages/monsters discarded —
			# the boss owns the island. Home = the island's center tile (always
			# interior => walkable).
			for v in res_base:
				resources.append(pts[res_off + v])
				resource_tiers.append(tier)
			boss_islands.append(i)
			boss_spawns.append(_tile_center(Vector2i(
				isl[i].position.x + isl[i].size.x / 2,
				isl[i].position.y + isl[i].size.y / 2)))
			boss_tiers.append(tier)
		else:
			# Field island: danger scales with tier — more orbs, more monsters.
			for v in res_base + tier:
				resources.append(pts[res_off + v])
				resource_tiers.append(tier)
			for v in mon_base + tier:
				monster_spawns.append(pts[mon_off + v])
				monster_tiers.append(tier)
			if mid_set.has(i):
				merchants.append(pts[total_k - 1])

	# 6) Assemble. walkable = islands ++ bridges (fixed order). Convert tiles→world.
	var g := WorldGeometry.new()
	var aabb := Rect2i()
	var first := true
	for i in n_cells:
		var wr := _to_world(isl[i])
		g.islands.append(wr)
		g.island_biomes.append(biomes[i])
		g.island_tiers.append(tiers[i])
		g.island_factions.append(i + 1 if i < 4 else 0)
		g.walkable.append(wr)
		if first: aabb = isl[i]; first = false
		else: aabb = aabb.merge(isl[i])
	for j in bridges_t.size():
		var wr2 := _to_world(bridges_t[j])
		g.bridges.append(wr2)
		g.bridge_biomes.append(biomes[bridge_parent[j]])
		g.walkable.append(wr2)
		aabb = aabb.merge(bridges_t[j])
	for v in villages: g.villages.append(v)
	for f in village_factions: g.village_factions.append(f)
	for v in merchants: g.merchants.append(v)
	for v in resources: g.resources.append(v)
	for t in resource_tiers: g.resource_tiers.append(t)
	for j in caches.size():
		g.caches.append(caches[j])
		g.cache_tiers.append(cache_tiers[j])
	for j in monster_spawns.size():
		g.monster_spawns.append(monster_spawns[j])
		g.monster_tiers.append(monster_tiers[j])
	for j in boss_islands.size():
		var bi: int = boss_islands[j]
		g.boss_islands.append(bi)
		g.boss_spawns.append(boss_spawns[j])
		g.boss_kits.append(BossDefs.kit_for_biome(biomes[bi]))
		g.boss_tiers.append(boss_tiers[j])
	# bounds: padded AABB in world space (camera limits / water rect).
	var pad := 3
	g.bounds = Rect2(
		float((aabb.position.x - pad) * TS), float((aabb.position.y - pad) * TS),
		float((aabb.size.x + 2 * pad) * TS), float((aabb.size.y + 2 * pad) * TS))
	return g

# --- helpers -----------------------------------------------------------------

## Ring distance (Chebyshev, in cells) -> danger tier 0..MAX_TIER. Integer math
## only: corners (ring == max_ring) are 0, the center (ring 0) is MAX_TIER.
static func _tier_for_ring(ring: int, max_ring: int) -> int:
	@warning_ignore("integer_division")
	return (max_ring - ring) * MAX_TIER / max_ring

## Draw one bridge between islands a/b and append its segments. EXACTLY 2 rng
## calls (bw, jog_pct), drawn unconditionally so the stream length per edge is
## constant. Even width keeps hw = bw/2 exact and symmetric. jog_pct is snapped
## at the ends (JOG_SNAP) so some bridges become L-turns instead of Z-turns.
static func _append_bridge(bridges_t: Array, bridge_parent: Array, isl: Array,
		a: int, b: int, rng: RandomNumberGenerator) -> void:
	@warning_ignore("integer_division")
	var bw: int = rng.randi_range(BRIDGE_W_MIN / 2, BRIDGE_W_MAX / 2) * 2
	var jog_pct: int = rng.randi_range(0, 100)
	if jog_pct < JOG_SNAP:
		jog_pct = 0
	elif jog_pct > 100 - JOG_SNAP:
		jog_pct = 100
	# Never wider than the smaller island it joins (defense in depth — with
	# ISLAND_MIN 24 the cap is 22, above BRIDGE_W_MAX). Pure clamp, no rng.
	var cap: int = mini(isl[a].size.x, isl[a].size.y)
	cap = mini(cap, mini(isl[b].size.x, isl[b].size.y)) - 2
	bw = mini(bw, cap)
	bw -= bw % 2   # keep even
	for seg in _bridge_segments(isl[a], isl[b], bw, jog_pct):
		bridges_t.append(seg)
		bridge_parent.append(a)

## Deterministic Fisher-Yates with the seeded rng (Array.shuffle() uses the global
## RNG and would break determinism).
static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

## One biome per island: distinct while island_count <= BIOME_COUNT, else differ
## from the previously assigned island.
static func _biome_pool(n: int, rng: RandomNumberGenerator) -> Array:
	var count: int = BiomeRegistry.BIOME_COUNT
	var pool: Array = []
	for b in count:
		pool.append(b)
	_shuffle(pool, rng)
	var out: Array = []
	for i in n:
		if i < pool.size():
			out.append(pool[i])
		else:
			var prev: int = out[i - 1] if i > 0 else -1
			var b: int = rng.randi_range(0, count - 1)
			if count > 1 and b == prev:
				b = (b + 1) % count
			out.append(b)
	return out

## Build the 3 rect segments of a bridge connecting islands A and B as a dog-leg:
## an arm leaving A along the DOMINANT axis of the A->B delta, a perpendicular
## jog arm, then an arm entering B. `jog_pct` (0..100) places the turn between
## the centers; snapped 0/100 collapses one bend into pure overlap (an L-turn).
## Every consecutive arm pair meets in a bw-by-bw corner, and the end arms overlap
## A / B by bw in one axis and >= hw in the other, so with bw >= BRIDGE_W_MIN (4
## tiles) every seam clears the > 2*ENTITY_RADIUS (1 tile) overlap the WorldGeometry
## lemma needs. Degenerate cases (jog at an end, aligned centers) only add overlap
## and never produce a zero-size rect (each arm is always bw wide/tall).
static func _bridge_segments(a: Rect2i, b: Rect2i, bw: int, jog_pct: int) -> Array:
	@warning_ignore("integer_division")
	var acx: int = a.position.x + a.size.x / 2
	@warning_ignore("integer_division")
	var acy: int = a.position.y + a.size.y / 2
	@warning_ignore("integer_division")
	var bcx: int = b.position.x + b.size.x / 2
	@warning_ignore("integer_division")
	var bcy: int = b.position.y + b.size.y / 2
	@warning_ignore("integer_division")
	var hw: int = bw / 2
	var segs: Array = []
	if absi(bcy - acy) > absi(bcx - acx):
		# V-H-V: vertical at A's column to the turn row, horizontal along it,
		# vertical at B's column into B. Transposed mirror of the H-V-H case.
		@warning_ignore("integer_division")
		var my: int = acy + (bcy - acy) * jog_pct / 100
		var v1y0: int = mini(acy, my) - hw
		var v1y1: int = maxi(acy, my) + hw
		segs.append(Rect2i(acx - hw, v1y0, bw, v1y1 - v1y0))
		var hx0: int = mini(acx, bcx) - hw
		var hx1: int = maxi(acx, bcx) + hw
		segs.append(Rect2i(hx0, my - hw, hx1 - hx0, bw))
		var v3y0: int = mini(my, bcy) - hw
		var v3y1: int = maxi(my, bcy) + hw
		segs.append(Rect2i(bcx - hw, v3y0, bw, v3y1 - v3y0))
	else:
		# H-V-H: horizontal at A's row to the turn column, vertical down it,
		# horizontal at B's row into B.
		@warning_ignore("integer_division")
		var mx: int = acx + (bcx - acx) * jog_pct / 100
		var h1x0: int = mini(acx, mx) - hw
		var h1x1: int = maxi(acx, mx) + hw
		segs.append(Rect2i(h1x0, acy - hw, h1x1 - h1x0, bw))
		var vy0: int = mini(acy, bcy) - hw
		var vy1: int = maxi(acy, bcy) + hw
		segs.append(Rect2i(mx - hw, vy0, bw, vy1 - vy0))
		var h3x0: int = mini(mx, bcx) - hw
		var h3x1: int = maxi(mx, bcx) + hw
		segs.append(Rect2i(h3x0, bcy - hw, h3x1 - h3x0, bw))
	return segs

## `count` distinct interior tile centers of an island (world coords), inset by
## `border` tiles on each side (keeps spawns/orbs off the shoreline so the entity
## disk fits). Samples directly from the seeded rng. Deterministic: identical seed
## ⇒ identical draws and identical collision/retry decisions on both ends. The
## smallest island interior is (ISLAND_MIN - 2*BORDER)^2 = 256 tiles vs <= ~17
## draws, so the retry loop ~never runs long.
static func _sample_interior(r: Rect2i, border: int, count: int, rng: RandomNumberGenerator) -> Array:
	var x0: int = r.position.x + border
	var y0: int = r.position.y + border
	var x1: int = r.position.x + r.size.x - border - 1   # inclusive for randi_range
	var y1: int = r.position.y + r.size.y - border - 1
	var used := {}                                        # Vector2i -> true (membership)
	var out: Array = []
	if x1 < x0 or y1 < y0:
		return out                                        # island too small (never at ISLAND_MIN=24)
	for _i in count:
		var t := Vector2i(rng.randi_range(x0, x1), rng.randi_range(y0, y1))
		var tries := 0
		while used.has(t) and tries < 16:                 # interior >> count ⇒ ~never loops
			t = Vector2i(rng.randi_range(x0, x1), rng.randi_range(y0, y1))
			tries += 1
		used[t] = true
		out.append(_tile_center(t))
	return out

## Tile coord → world position at the tile's center (exact: 16*int + 8).
static func _tile_center(t: Vector2i) -> Vector2:
	@warning_ignore("integer_division")
	return Vector2(float(t.x * TS + TS / 2), float(t.y * TS + TS / 2))

## Tile-space Rect2i → world-space Rect2.
static func _to_world(r: Rect2i) -> Rect2:
	return Rect2(float(r.position.x * TS), float(r.position.y * TS),
		float(r.size.x * TS), float(r.size.y * TS))
