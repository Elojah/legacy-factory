extends SceneTree
## Standalone determinism + connectivity test for WorldGenerator. Run with:
##   godot-4 --headless --path . --script res://tools/test_worldgen.gd
## Asserts: same seed ⇒ identical geometry; different seeds ⇒ different geometry;
## the walkable union is fully connected via seams overlapping by > 2*radius (the
## constraint that makes WorldGeometry.resolve_circle gap-free); a point in open
## water resolves back onto a walkable rect; and the corner-start / center-danger
## layout laws (corner faction islands, tier gradient, center-out bosses,
## corner + mid-ring merchants, tiered monster counts, bridge segment count).

func _initialize() -> void:
	var sizes := [WorldGenerator.SIZE_SMALL, WorldGenerator.SIZE_MEDIUM, WorldGenerator.SIZE_LARGE]
	var seeds := [1, 2, 42, 1000, 999999]
	var fails := 0
	var checks := 0

	for size in sizes:
		var hashes := {}
		for s in seeds:
			var g1 := WorldGenerator.generate(s, size)
			var g2 := WorldGenerator.generate(s, size)
			checks += 1
			if g1.debug_hash() != g2.debug_hash():
				fails += 1
				print("FAIL determinism: size=%d seed=%d" % [size, s])
			hashes[s] = g1.debug_hash()
			# Connectivity of the walkable union.
			checks += 1
			if not _connected(g1):
				fails += 1
				print("FAIL connectivity: size=%d seed=%d (walkable not one component)" % [size, s])
			# Every village/merchant/resource/monster/boss point sits on walkable ground.
			checks += 1
			if not _all_on_land(g1):
				fails += 1
				print("FAIL placement: size=%d seed=%d (a spawn/orb is off walkable land)" % [size, s])
			# No walkable rect is degenerate (a bridge dog-leg arm collapsed to 0 size).
			checks += 1
			if not _all_positive_size(g1):
				fails += 1
				print("FAIL degenerate: size=%d seed=%d (a walkable rect has zero/negative size)" % [size, s])
			# resolve_circle pulls a far-water point back onto land.
			checks += 1
			var far := g1.bounds.position - Vector2(500, 500)
			var fixed := g1.resolve_circle(far, NetConfig.ENTITY_RADIUS)
			if not _on_land(g1, fixed):
				fails += 1
				print("FAIL resolve: size=%d seed=%d (water point not pushed onto land)" % [size, s])
			# Corner faction starts + the center-out danger tier law.
			checks += 1
			if not _layout_ok(g1, size):
				fails += 1
				print("FAIL layout: size=%d seed=%d" % [size, s])
			# Bosses: count, center apex, innermost-first promotion, tiers, kits.
			checks += 1
			if not _boss_ok(g1, size):
				fails += 1
				print("FAIL bosses: size=%d seed=%d" % [size, s])
			# Villages: per-corner, faction-tagged, cover the player cap.
			checks += 1
			if not _villages_ok(g1, size):
				fails += 1
				print("FAIL villages: size=%d seed=%d" % [size, s])
			# Merchants: 4 corner shops + the mid-ring neutral shops.
			checks += 1
			if not _merchants_ok(g1, size):
				fails += 1
				print("FAIL merchants: size=%d seed=%d" % [size, s])
			# Monsters: field islands only, count and tier follow the island tier.
			checks += 1
			if not _monsters_ok(g1, size):
				fails += 1
				print("FAIL monsters: size=%d seed=%d" % [size, s])
			# Resource orbs: tier-tagged with the hosting island's danger tier.
			checks += 1
			if not _resources_ok(g1):
				fails += 1
				print("FAIL resources: size=%d seed=%d" % [size, s])
			# Secret caches: one per shortcut bridge, on a bridge rect, tier-tagged.
			checks += 1
			if not _caches_ok(g1, size):
				fails += 1
				print("FAIL caches: size=%d seed=%d" % [size, s])
			# Bridges: (islands - 1) tree edges + extra shortcuts, 3 segments each.
			checks += 1
			var cfg: Dictionary = WorldGenerator.PRESETS[size]
			var expected_segs: int = (g1.islands.size() - 1 + int(cfg["extra_bridges"])) * 3
			if g1.bridges.size() != expected_segs:
				fails += 1
				print("FAIL bridges: size=%d seed=%d (%d segments, expected %d)" % [size, s, g1.bridges.size(), expected_segs])
		# Variety: distinct seeds should give distinct maps.
		var distinct := {}
		for s in seeds:
			distinct[hashes[s]] = true
		checks += 1
		if distinct.size() < seeds.size():
			fails += 1
			print("FAIL variety: size=%d produced duplicate maps across seeds" % size)

	print("worldgen test: %d checks, %d failures" % [checks, fails])
	print("RESULT: %s" % ("PASS" if fails == 0 else "FAIL"))
	quit(0 if fails == 0 else 1)

## The grid cell an island occupies (world px -> cell coords via its center).
func _cell_of(r: Rect2) -> Vector2i:
	var cpx := r.get_center()
	var cell_px := float(WorldGenerator.CELL * WorldGenerator.TS)
	return Vector2i(int(cpx.x / cell_px), int(cpx.y / cell_px))

## Chebyshev ring of a cell around the grid center.
func _ring_of(cell: Vector2i, size: int) -> int:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	@warning_ignore("integer_division")
	var center := Vector2i(int(cfg["cols"]) / 2, int(cfg["rows"]) / 2)
	return maxi(absi(cell.x - center.x), absi(cell.y - center.y))

func _max_ring(size: int) -> int:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	@warning_ignore("integer_division")
	return maxi(1, maxi(int(cfg["cols"]) / 2, int(cfg["rows"]) / 2))

## Corner starts + tier law: islands 0-3 sit in the 4 grid corners with factions
## 1-4 and tier 0; island 4 sits in the center cell with tier MAX_TIER; every
## island's tier matches the ring formula recomputed from its rect.
func _layout_ok(g: WorldGeometry, size: int) -> bool:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	var cols: int = int(cfg["cols"])
	var rows: int = int(cfg["rows"])
	if g.island_tiers.size() != g.islands.size() or g.island_factions.size() != g.islands.size():
		print("  tier/faction arrays not parallel to islands")
		return false
	var corners: Array = [
		Vector2i(0, 0), Vector2i(cols - 1, 0),
		Vector2i(0, rows - 1), Vector2i(cols - 1, rows - 1),
	]
	for i in 4:
		if _cell_of(g.islands[i]) != corners[i]:
			print("  island %d not in corner cell %s" % [i, corners[i]])
			return false
		if g.island_factions[i] != i + 1:
			print("  island %d faction %d, expected %d" % [i, g.island_factions[i], i + 1])
			return false
		if g.island_tiers[i] != 0:
			print("  corner island %d tier %d, expected 0" % [i, g.island_tiers[i]])
			return false
	@warning_ignore("integer_division")
	var center := Vector2i(cols / 2, rows / 2)
	if _cell_of(g.islands[4]) != center:
		print("  island 4 not in center cell %s" % center)
		return false
	if g.island_tiers[4] != WorldGenerator.MAX_TIER:
		print("  center island tier %d, expected %d" % [g.island_tiers[4], WorldGenerator.MAX_TIER])
		return false
	var mr := _max_ring(size)
	for i in g.islands.size():
		var ring := _ring_of(_cell_of(g.islands[i]), size)
		@warning_ignore("integer_division")
		var want: int = (mr - ring) * WorldGenerator.MAX_TIER / mr
		if g.island_tiers[i] != want:
			print("  island %d tier %d, ring law says %d" % [i, g.island_tiers[i], want])
			return false
		if g.island_factions[i] != 0 and i >= 4:
			print("  non-corner island %d has faction %d" % [i, g.island_factions[i]])
			return false
	return true

## A point is on land if it lies inside some walkable rect.
func _on_land(g: WorldGeometry, p: Vector2) -> bool:
	for r in g.walkable:
		if r.has_point(p):
			return true
	return false

func _all_on_land(g: WorldGeometry) -> bool:
	for arr in [g.villages, g.merchants, g.resources, g.caches, g.monster_spawns, g.boss_spawns]:
		for p in arr:
			if not _on_land(g, p):
				return false
	return true

## Resource orbs: tier array parallel, and each orb's tier equals the danger tier
## of the island whose rect contains it (the gem award law).
func _resources_ok(g: WorldGeometry) -> bool:
	if g.resource_tiers.size() != g.resources.size():
		print("  resource_tiers not parallel")
		return false
	for j in g.resources.size():
		var host := -1
		for i in g.islands.size():
			if g.islands[i].has_point(g.resources[j]):
				host = i
				break
		if host < 0:
			print("  orb %d not on any island" % j)
			return false
		if g.resource_tiers[j] != g.island_tiers[host]:
			print("  orb %d tier %d != island %d tier %d" % [j, g.resource_tiers[j], host, g.island_tiers[host]])
			return false
	return true

## Secret caches: exactly one per SHORTCUT bridge edge (total edges - tree edges),
## each sitting on a bridge rect (never island interior decoration), tiers parallel
## and within 0..MAX_TIER.
func _caches_ok(g: WorldGeometry, size: int) -> bool:
	@warning_ignore("integer_division")
	var edges: int = g.bridges.size() / 3
	var expected: int = edges - (g.islands.size() - 1)
	if g.caches.size() != expected or g.cache_tiers.size() != g.caches.size():
		print("  %d caches (tiers %d), expected %d" % [g.caches.size(), g.cache_tiers.size(), expected])
		return false
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	if expected != int(cfg["extra_bridges"]):
		print("  cache count %d != preset extra_bridges %d" % [expected, int(cfg["extra_bridges"])])
		return false
	for j in g.caches.size():
		if g.cache_tiers[j] < 0 or g.cache_tiers[j] > WorldGenerator.MAX_TIER:
			print("  cache %d tier %d out of range" % [j, g.cache_tiers[j]])
			return false
		var on_bridge := false
		for r in g.bridges:
			if r.has_point(g.caches[j]):
				on_bridge = true
				break
		if not on_bridge:
			print("  cache %d not on a bridge rect" % j)
			return false
	return true

## Villages: exactly 4 * ceil(players/4), faction-tagged 1-4, each inside its
## faction's corner island, and together they cover the player cap.
func _villages_ok(g: WorldGeometry, size: int) -> bool:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	var vill_per := ceili(float(cfg["players"]) / 4.0)
	if g.villages.size() != 4 * vill_per or g.village_factions.size() != g.villages.size():
		print("  %d villages (factions %d), expected %d" % [g.villages.size(), g.village_factions.size(), 4 * vill_per])
		return false
	if g.villages.size() < int(cfg["players"]):
		print("  only %d villages for %d players" % [g.villages.size(), int(cfg["players"])])
		return false
	for i in g.villages.size():
		var f: int = g.village_factions[i]
		if f < 1 or f > 4:
			print("  village %d has faction %d" % [i, f])
			return false
		if not g.islands[f - 1].has_point(g.villages[i]):
			print("  faction %d village not on its corner island" % f)
			return false
	return true

## Merchants: one per corner island (beside its first village) + mid_merchants
## neutral shops, each ON a non-boss island (a boss island's shop would be
## unreachable loot).
func _merchants_ok(g: WorldGeometry, size: int) -> bool:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	var expected: int = 4 + int(cfg["mid_merchants"])
	if g.merchants.size() != expected:
		print("  %d merchants, expected %d" % [g.merchants.size(), expected])
		return false
	for p in g.merchants:
		var on_island := false
		for i in g.islands.size():
			if g.islands[i].has_point(p):
				on_island = true
				if i in g.boss_islands:
					print("  merchant on boss island %d" % i)
					return false
		if not on_island:
			print("  merchant off-island at %s" % p)
			return false
	return true

## Boss invariants: preset count, parallel arrays (spawns/kits/tiers), kits in
## range, the center island is the apex (tier MAX_TIER), corners are never
## bosses, promoted bosses are the innermost fill islands, and boss islands hold
## no villages or monster spawns.
func _boss_ok(g: WorldGeometry, size: int) -> bool:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	var expected: int = mini(int(cfg.get("bosses", 0)), g.islands.size() - 4)
	if g.boss_islands.size() != expected or g.boss_spawns.size() != expected \
	or g.boss_kits.size() != expected or g.boss_tiers.size() != expected:
		print("  boss arrays: %d/%d/%d/%d expected %d" % [g.boss_islands.size(), g.boss_spawns.size(), g.boss_kits.size(), g.boss_tiers.size(), expected])
		return false
	if expected > 0 and not 4 in g.boss_islands:
		print("  center island 4 is not a boss island")
		return false
	for kit in g.boss_kits:
		if kit < 0 or kit >= BossDefs.KIT_COUNT:
			print("  bad kit %d" % kit)
			return false
	# Promotion law: every promoted (non-center) boss ring <= every non-boss
	# fill island ring (innermost-first, index tie-breaks allow equality).
	var max_boss_ring := 0
	var min_free_ring := 1 << 30
	for i in range(5, g.islands.size()):
		var ring := _ring_of(_cell_of(g.islands[i]), size)
		if i in g.boss_islands:
			max_boss_ring = maxi(max_boss_ring, ring)
		else:
			min_free_ring = mini(min_free_ring, ring)
	if g.boss_islands.size() > 1 and max_boss_ring > min_free_ring:
		print("  promoted boss ring %d beyond a free fill island ring %d" % [max_boss_ring, min_free_ring])
		return false
	for j in g.boss_islands.size():
		var bi: int = g.boss_islands[j]
		if bi < 4:
			print("  corner island %d is a boss island" % bi)
			return false
		if g.boss_tiers[j] != g.island_tiers[bi]:
			print("  boss tier %d != island tier %d" % [g.boss_tiers[j], g.island_tiers[bi]])
			return false
		var rect: Rect2 = g.islands[bi]
		for p in g.villages:
			if rect.has_point(p):
				print("  village on boss island %d" % bi)
				return false
		for p in g.monster_spawns:
			if rect.has_point(p):
				print("  monster spawn on boss island %d" % bi)
				return false
	return true

## Monsters live only on field islands (index >= 5, non-boss), tier matches the
## hosting island, and each field island holds exactly mon + tier of them.
func _monsters_ok(g: WorldGeometry, size: int) -> bool:
	var cfg: Dictionary = WorldGenerator.PRESETS[size]
	if g.monster_tiers.size() != g.monster_spawns.size():
		print("  monster_tiers not parallel")
		return false
	var per_island := {}
	for j in g.monster_spawns.size():
		var host := -1
		for i in g.islands.size():
			if g.islands[i].has_point(g.monster_spawns[j]):
				host = i
				break
		if host < 5 or host in g.boss_islands:
			print("  monster %d on island %d (not a field island)" % [j, host])
			return false
		if g.monster_tiers[j] != g.island_tiers[host]:
			print("  monster tier %d != island %d tier %d" % [g.monster_tiers[j], host, g.island_tiers[host]])
			return false
		per_island[host] = per_island.get(host, 0) + 1
	for i in range(5, g.islands.size()):
		if i in g.boss_islands:
			continue
		var want: int = int(cfg["mon"]) + g.island_tiers[i]
		if per_island.get(i, 0) != want:
			print("  field island %d has %d monsters, expected %d" % [i, per_island.get(i, 0), want])
			return false
	return true

## No walkable rect may have zero/negative extent: a bridge dog-leg arm must always
## be a real bw-wide/tall strip (degenerate arms would be invisible dead ends).
func _all_positive_size(g: WorldGeometry) -> bool:
	for r in g.walkable:
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			return false
	return true

## BFS over walkable rects; two rects are linked if their overlap exceeds 2*radius
## in BOTH axes (the same seam condition resolve_circle relies on). All reachable
## from rect 0 ⇒ the union is one traversable component.
func _connected(g: WorldGeometry) -> bool:
	var n := g.walkable.size()
	if n <= 1:
		return true
	var seen := {0: true}
	var stack := [0]
	var min_overlap := 2.0 * NetConfig.ENTITY_RADIUS
	while not stack.is_empty():
		var i: int = stack.pop_back()
		for j in n:
			if seen.has(j):
				continue
			var o := g.walkable[i].intersection(g.walkable[j])
			if o.size.x > min_overlap and o.size.y > min_overlap:
				seen[j] = true
				stack.append(j)
	return seen.size() == n
