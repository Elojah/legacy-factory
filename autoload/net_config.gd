extends Node
## NetConfig — const-only network & simulation tuning. No logic, no state.
## Registered as an autoload so both client and server share identical numbers.
## Anything that affects the deterministic simulation MUST live here as a const
## so client prediction and server authority use the exact same values.

# --- Transport ----------------------------------------------------------------
const DEFAULT_PORT: int = 24565
const DEFAULT_BIND_IP: String = "*"
const DEFAULT_CONNECT_IP: String = "127.0.0.1"
const MAX_PEERS: int = 32
const SERVER_PEER_ID: int = 1

# ENet channels. Channel 0 is ENet's default control channel; we reserve it for
# reliable lifecycle/handshake traffic and use dedicated channels for the rest.
const CH_EVENT: int = 0      # reliable: spawn/despawn, handshake, clock sync
const CH_INPUT: int = 1      # unreliable_ordered: client -> server input commands
const CH_SNAPSHOT: int = 2   # unreliable_ordered: server -> client world snapshots
const CHANNEL_COUNT: int = 3

# --- Fixed-tick simulation ----------------------------------------------------
const TICK_RATE: int = 30                       # must equal physics_ticks_per_second
const DT: float = 1.0 / float(TICK_RATE)        # use THIS for sim math, never frame delta
const SNAPSHOT_EVERY_TICKS: int = 1             # broadcast cadence (1 == every tick)

# --- Prediction / reconciliation ----------------------------------------------
const INPUT_BUFFER_SIZE: int = 64               # ring buffer of unacked inputs
const INPUT_REDUNDANCY: int = 3                 # recent inputs piggybacked per packet
const RECONCILE_SNAP_THRESHOLD_PX: float = 0.5  # below this, accept prediction as-is
const RECONCILE_SMOOTH_THRESHOLD_PX: float = 64.0 # above this, hard snap instead of smooth

# --- Interpolation ------------------------------------------------------------
const INTERP_DELAY_TICKS: int = 4               # render remote entities this far in the past
const INTERP_BUFFER_TICKS: int = 32             # how many snapshots to retain per entity

# --- Clock sync ---------------------------------------------------------------
const PING_INTERVAL_SEC: float = 1.0
const CLOCK_SMOOTHING: float = 0.1              # EMA factor for server-tick estimate

# --- Gameplay tuning (deterministic) ------------------------------------------
const PLAYER_SPEED: float = 140.0               # px/sec
const MONSTER_SPEED: float = 70.0               # px/sec
const ENTITY_RADIUS: float = 8.0                # circle collider radius for sim collision
const PLAYER_MAX_HP: int = 100
const MONSTER_MAX_HP: int = 120

# --- Raid bosses (deterministic tuning; see shared/combat/boss_defs.gd) --------
const BOSS_SPEED: float = 55.0        # px/sec — slow, inexorable
const BOSS_RADIUS: float = 28.0       # collision radius (others keep ENTITY_RADIUS)
const BOSS_MAX_HP: int = 45000        # u16-safe; ~4 min kill @ 15 players (~12 dps each)

# --- Time of day (cosmetic; drives the client sky, never the sim) --------------
# A full dawn->day->dusk->night->dawn cycle spans this many ticks. The client
# derives time-of-day from the synchronized GameClock tick, so every peer in a
# lobby sees the same sky. Kept here (shared const) so the value lives in one place.
const DAY_LENGTH_TICKS: int = 12 * 60 * TICK_RATE   # 21600 ticks = 12 real minutes / day

# Entity kinds.
const KIND_PLAYER: int = 0
const KIND_MONSTER: int = 1
const KIND_PROJECTILE: int = 2
const KIND_BOSS: int = 3
const KIND_HAZARD: int = 4    # boss ground zone; not collidable, not targetable

# Input button bitmask (wire: u8, so player-sent bits must stay < 8 — all 8
# are now taken; the next player button costs a wire-format change).
const BTN_ATTACK: int = 1 << 0
const BTN_INTERACT: int = 1 << 1
const BTN_BOLT: int = 1 << 2
const BTN_DASH: int = 1 << 3
const BTN_HEAL: int = 1 << 4
const BTN_SLAM: int = 1 << 5
const BTN_NOVA: int = 1 << 6    # merchant-unlocked; sim ladder gates on upgrades
const BTN_VOLLEY: int = 1 << 7  # merchant-unlocked; sim ladder gates on upgrades

# AI-ONLY boss buttons — NEVER added to Lobby.push_input's mask, so players can
# never cast them. AI InputCommands are inserted server-side and never serialize,
# which is why bits >= 8 are safe here despite the u8 wire field.
const BTN_BOSS_SMASH: int = 1 << 8
const BTN_BOSS_BARRAGE: int = 1 << 9
const BTN_BOSS_SUMMON: int = 1 << 10
const BTN_BOSS_HAZARD: int = 1 << 11
const BTN_BOSS_CHARGE: int = 1 << 12
