class_name AbilityDefs
## The shared ability tuning, indexed by ability id. Every character has the
## same base kit of 5 skills (class is visual only — the sim never reads it);
## ids 5-9 are the boss pool, cast only by server AI via the BTN_BOSS_* button
## bits (never in Lobby.push_input's mask, so players can't reach them); ids
## 10-11 are merchant-unlocked player skills gated on UpgradeDefs bits. All
## timings are in ticks (30 Hz); cooldowns must stay <= 255 because EntityState
## serializes each slot as a u8 — and every id added here costs one cooldown
## byte per entity per snapshot, which is why the 3 boss kits SHARE this pool.

const MELEE: int = 0
const BOLT: int = 1
const DASH: int = 2
const HEAL: int = 3
const SLAM: int = 4
const BOSS_SMASH: int = 5     # huge telegraphed slam around the boss
const BOSS_BARRAGE: int = 6   # radial ring of projectiles
const BOSS_SUMMON: int = 7    # server spawns minions (Lobby hook)
const BOSS_HAZARD: int = 8    # server drops ground damage zones (Lobby hook)
const BOSS_CHARGE: int = 9    # rush along facing; damage at the arrival point
const NOVA: int = 10          # merchant-unlocked: big PBAoE burst around the caster
const VOLLEY: int = 11        # merchant-unlocked: 3-bolt spread along facing
const ABILITY_COUNT: int = 12

# The hotbar/player-facing kit, in slot order. Ids are NOT contiguous anymore
# (the unlockables sit after the boss pool), so UI must map slot -> id through
# this array, never assume slot i == ability id i. NOVA/VOLLEY casts are gated
# on their UpgradeDefs unlock bits in the WorldSim button ladder.
const PLAYER_ABILITIES: Array[int] = [MELEE, BOLT, DASH, HEAL, SLAM, NOVA, VOLLEY]
const PLAYER_ABILITY_COUNT: int = 7

# Phase timings per ability id (index = ability id).
#                                 MELEE BOLT DASH HEAL SLAM SMASH BARR SUMM  HAZ CHARGE NOVA VOLLEY
const WINDUP_TICKS: Array[int]   = [12,   8,   0,  20,  18,   30,  24,  36,  30,  12,   24,  10]
const ACTIVE_TICKS: Array[int]   = [ 4,   2,   6,   1,   2,    2,   2,   2,   2,  18,    2,   2]
const RECOVERY_TICKS: Array[int] = [10,   6,   2,   8,  12,   20,  30,  24,  24,  24,   14,   8]
const COOLDOWN_TICKS: Array[int] = [20,  45,  60, 240, 150,   90, 150, 255, 210, 240,  210, 120]
# Whether the WINDUP/ACTIVE phases lock movement (dash/charge override it).
const ROOTED: Array[bool] = [true, true, false, true, true, true, true, true, true, false, true, true]

# MELEE — telegraphed cone swing (the original ability, tuning unchanged).
const MELEE_RANGE: float = 30.0
const MELEE_ARC_DEGREES: float = 120.0
const MELEE_DAMAGE: int = 20

# BOLT — server-spawned projectile fired along facing.
const BOLT_SPEED: float = 360.0       # px/sec
const BOLT_RADIUS: float = 3.0        # collision radius of the projectile
const BOLT_DAMAGE: int = 15
const BOLT_TTL_TICKS: int = 36        # 1.2 s of flight
const BOLT_SPAWN_GAP: float = 2.0     # clearance between caster edge and bolt edge

# DASH — burst of speed along facing; input direction is ignored while active.
const DASH_SPEED: float = 490.0       # 3.5x player speed

# HEAL — self heal on a long cooldown, capped at the entity's max HP. The
# alliance perk splashes the same amount to nearby same-faction/allied players.
const HEAL_AMOUNT: int = 40
const HEAL_SPLASH_RADIUS: float = 80.0

# SLAM — damage everything in a radius around the caster.
const SLAM_RADIUS: float = 70.0
const SLAM_DAMAGE: int = 35

# --- Boss pool (shared by all 3 kits; kits differ in AI patterns, not ids) -----

# BOSS_SMASH — huge telegraphed ground slam around the boss (1 s windup).
const SMASH_RADIUS: float = 90.0
const SMASH_DAMAGE: int = 45          # 2 hits kill a 100-hp player: spread + heal

# BOSS_BARRAGE — radial ring of server-spawned projectiles.
const BARRAGE_COUNT: int = 12
const BARRAGE_SPEED: float = 240.0    # slower than player bolts: dodgeable
const BARRAGE_DAMAGE: int = 20
const BARRAGE_TTL_TICKS: int = 45

# BOSS_SUMMON — server spawns minions around the boss (owner_id = boss).
const SUMMON_COUNT: int = 3           # per cast
const SUMMON_MAX_LIVE: int = 6        # live-minion cap per boss

# BOSS_HAZARD — ground damage zones dropped under the nearest players.
const HAZARD_SPAWN_COUNT: int = 3
const HAZARD_RADIUS: float = 40.0
const HAZARD_DAMAGE: int = 8          # per damage tick while standing inside
const HAZARD_TICK_INTERVAL: int = 15  # damage every 0.5 s -> 16 dps
const HAZARD_TTL_TICKS: int = 180     # 6 s; must fit the u8 ability_timer

# BOSS_CHARGE — gap-closer; the counterplay is dodging the LANDING zone.
const CHARGE_SPEED: float = 420.0     # 18 active ticks -> ~252 px rush
const CHARGE_IMPACT_RADIUS: float = 50.0
const CHARGE_DAMAGE: int = 30

# --- Merchant-unlocked player skills (UpgradeDefs unlock bits gate the casts) ---

# NOVA — long-windup burst around the caster; bigger than slam, hits harder.
const NOVA_RADIUS: float = 110.0
const NOVA_DAMAGE: int = 45

# VOLLEY — 3 server-spawned bolts in a spread along facing (the bolt pattern).
const VOLLEY_COUNT: int = 3
const VOLLEY_SPREAD_DEGREES: float = 15.0  # per step off center: -15 / 0 / +15
const VOLLEY_DAMAGE: int = 12              # per shard; all 3 landing beats one bolt
const VOLLEY_SPEED: float = 360.0
const VOLLEY_TTL_TICKS: int = 30

static func is_dash_active(s: EntityState) -> bool:
	return s.ability_phase == Ability.PHASE_ACTIVE and s.ability_id == DASH

## Speed of a movement-override ability while ACTIVE, or -1.0 if movement is
## normal. Dash and boss charge both replace velocity with facing * speed.
static func movement_override_speed(s: EntityState) -> float:
	if s.ability_phase != Ability.PHASE_ACTIVE:
		return -1.0
	if s.ability_id == DASH:
		return DASH_SPEED
	if s.ability_id == BOSS_CHARGE:
		return CHARGE_SPEED
	return -1.0

# Projectile damage moved to UpgradeDefs.projectile_damage_for — it now also
# depends on the caster's upgrades stamped on the projectile at spawn.
