class_name Ability
## Deterministic ability state machine operating on an EntityState. One cast at
## a time: IDLE -> WINDUP -> ACTIVE -> RECOVERY -> IDLE (+cooldown on the used
## slot). Which ability is casting lives in s.ability_id; per-ability timings
## come from AbilityDefs. Tick-counted only. Called from WorldSim on BOTH
## client (prediction) and server (authority).

const PHASE_IDLE: int = 0
const PHASE_WINDUP: int = 1
const PHASE_ACTIVE: int = 2
const PHASE_RECOVERY: int = 3

## Try to begin casting `ability_id`. Returns true if it started this tick.
## A 0-tick windup (dash) still enters WINDUP here; the same tick's advance()
## pass moves it to ACTIVE, so the cast is live on the press tick.
static func try_start(s: EntityState, ability_id: int) -> bool:
	if s.ability_phase != PHASE_IDLE or s.ability_cds[ability_id] > 0 or not s.is_alive():
		return false
	s.ability_id = ability_id
	s.ability_phase = PHASE_WINDUP
	s.ability_timer = AbilityDefs.WINDUP_TICKS[ability_id]
	s.ability_has_hit = false
	return true

## Advance one tick. Handles cooldown decay and phase transitions.
static func advance(s: EntityState) -> void:
	for i in AbilityDefs.ABILITY_COUNT:
		if s.ability_cds[i] > 0:
			s.ability_cds[i] -= 1
	# Death cancels any in-progress cast (no cooldown charged).
	if not s.is_alive():
		s.ability_phase = PHASE_IDLE
		s.ability_timer = 0
		s.ability_has_hit = false
		return
	if s.ability_phase == PHASE_IDLE:
		return
	s.ability_timer -= 1
	if s.ability_timer > 0:
		return
	match s.ability_phase:
		PHASE_WINDUP:
			s.ability_phase = PHASE_ACTIVE
			s.ability_timer = AbilityDefs.ACTIVE_TICKS[s.ability_id]
			s.ability_has_hit = false
		PHASE_ACTIVE:
			s.ability_phase = PHASE_RECOVERY
			s.ability_timer = AbilityDefs.RECOVERY_TICKS[s.ability_id]
		PHASE_RECOVERY:
			s.ability_phase = PHASE_IDLE
			s.ability_timer = 0
			# Upgrade-aware (dash levels + FOCUS); identity when upgrades == 0.
			s.ability_cds[s.ability_id] = UpgradeDefs.cooldown_for(s.ability_id, s.upgrades)

## Movement is locked during the committed part of a cast — unless the ability
## itself is a movement (dash overrides velocity instead of zeroing it).
static func is_rooted(s: EntityState) -> bool:
	if s.ability_phase != PHASE_WINDUP and s.ability_phase != PHASE_ACTIVE:
		return false
	return AbilityDefs.ROOTED[s.ability_id]
