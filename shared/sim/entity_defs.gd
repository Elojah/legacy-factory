class_name EntityDefs
## Per-kind entity properties, shared by client prediction and server authority.
## The ONLY place that maps kind -> radius / max hp / sim role, so new kinds
## (boss, hazard) thread through movement, hit tests and respawns without
## scattering ternaries. Values for the original kinds are unchanged.

# Danger-tier hp tables (tier = UpgradeDefs.npc_tier, rides upgrades bits 0-1).
# Monster max hp as a % of MONSTER_MAX_HP: 120 / 192 / 264 / 336 (u16-safe).
const MONSTER_HP_PCT_BY_TIER: Array[int] = [100, 160, 220, 280]
# Boss max hp per tier; index 3 (the center apex) MUST equal NetConfig.BOSS_MAX_HP
# (45000) — the canonical 20-player raid value.
const BOSS_HP_BY_TIER: Array[int] = [6000, 12000, 24000, 45000]

## Circle collider radius used by movement and every hit test.
static func radius_for(kind: int) -> float:
	if kind == NetConfig.KIND_BOSS:
		return NetConfig.BOSS_RADIUS
	return NetConfig.ENTITY_RADIUS

## Full health for spawn/respawn and the heal cap.
static func max_hp_for(kind: int) -> int:
	match kind:
		NetConfig.KIND_PLAYER:
			return NetConfig.PLAYER_MAX_HP
		NetConfig.KIND_BOSS:
			return NetConfig.BOSS_MAX_HP
		_:
			return NetConfig.MONSTER_MAX_HP

## Per-ENTITY max hp: kind base + the VIGOR passive for players, danger tier
## (upgrades bits 0-1) for monsters and bosses. Use this wherever a concrete
## EntityState is in hand (heal caps, respawn fill, HUD, boss phases/reset);
## max_hp_for stays for kind-only contexts.
static func max_hp_of(s: EntityState) -> int:
	if s.kind == NetConfig.KIND_PLAYER:
		return NetConfig.PLAYER_MAX_HP + UpgradeDefs.max_hp_bonus(s.upgrades)
	if s.kind == NetConfig.KIND_MONSTER:
		@warning_ignore("integer_division")
		return NetConfig.MONSTER_MAX_HP * MONSTER_HP_PCT_BY_TIER[UpgradeDefs.npc_tier(s.upgrades)] / 100
	if s.kind == NetConfig.KIND_BOSS:
		return BOSS_HP_BY_TIER[UpgradeDefs.npc_tier(s.upgrades)]
	return max_hp_for(s.kind)

## Actors consume inputs and run the ability state machine each tick.
## Projectiles and hazards are transient effects driven by their own passes.
static func is_actor(kind: int) -> bool:
	return kind == NetConfig.KIND_PLAYER or kind == NetConfig.KIND_MONSTER \
		or kind == NetConfig.KIND_BOSS

## Targetable entities can be hit by melee cones, AoEs and projectiles.
## Hazards are hp-1 markers and must never absorb a hit meant for an actor.
static func is_targetable(kind: int) -> bool:
	return is_actor(kind)
