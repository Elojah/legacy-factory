class_name HitboxResolver
## Deterministic hit tests. NO physics queries — pure distance/angle math so
## prediction and authority agree exactly. Free-for-all is preserved for every
## pair involving a non-player-faction entity (monsters, bosses, summons);
## player-vs-player consults the lobby's faction `relations` table — only
## RIVAL factions damage each other (FactionDefs.are_hostile).
## Projectiles are never valid targets here (they die to their own flight pass).

## Return the ids of entities hit by attacker_id's melee swing this tick.
static func resolve(states: Dictionary, attacker_id: int, relations: int) -> Array:
	var hits: Array = []
	var a: EntityState = states.get(attacker_id, null)
	if a == null or not a.is_alive():
		return hits
	var base_reach := AbilityDefs.MELEE_RANGE + EntityDefs.radius_for(a.kind)
	var half_arc_cos := cos(deg_to_rad(AbilityDefs.MELEE_ARC_DEGREES * 0.5))
	var facing := a.facing.normalized() if a.facing.length() > 0.001 else Vector2.DOWN
	# Deterministic iteration order.
	var ids := states.keys()
	ids.sort()
	for id in ids:
		if id == attacker_id:
			continue
		var t: EntityState = states[id]
		if not EntityDefs.is_targetable(t.kind) or not t.is_alive():
			continue
		if not FactionDefs.are_hostile(a.faction, t.faction, relations):
			continue
		var to_target := t.pos - a.pos
		var dist := to_target.length()
		if dist > base_reach + EntityDefs.radius_for(t.kind) or dist < 0.0001:
			continue
		# Cone check via dot product against facing.
		if facing.dot(to_target / dist) >= half_arc_cos:
			hits.append(id)
	return hits

## Return the ids of entities within `radius` of attacker_id (slam-style AoE).
static func resolve_radius(states: Dictionary, attacker_id: int, radius: float, relations: int) -> Array:
	var hits: Array = []
	var a: EntityState = states.get(attacker_id, null)
	if a == null or not a.is_alive():
		return hits
	var ids := states.keys()
	ids.sort()
	for id in ids:
		if id == attacker_id:
			continue
		var t: EntityState = states[id]
		if not EntityDefs.is_targetable(t.kind) or not t.is_alive():
			continue
		if not FactionDefs.are_hostile(a.faction, t.faction, relations):
			continue
		if a.pos.distance_to(t.pos) <= radius + EntityDefs.radius_for(t.kind):
			hits.append(id)
	return hits
