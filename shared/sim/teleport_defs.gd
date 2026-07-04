class_name TeleportDefs
## Waypoint travel between villages/merchants: tuning, wire codes and the pure
## eligibility rules shared by the client UI (grey-out) and the server validator
## (Lobby.apply_teleport) so they can never disagree. Static consts + pure
## static funcs only (no autoload instance calls) — the UpgradeDefs discipline,
## so --script tools can depend on it.
##
## The teleport itself is NOT a sim ability: the cast (300+ ticks) and cooldown
## (7200 ticks) both overflow the u8 ability_timer/ability_cds wire fields, so
## they live server-side (Lobby._teleports + ServerPlayer.teleport_ready_tick,
## full ints, zero snapshot bytes). The channel cancels on move/damage instead
## of rooting: a channeling player stands still voluntarily, so client
## prediction stays exact and the completion snap is absorbed by the normal
## hard reconcile.

const TP_CAST_TICKS: int = 240      # 8 s — long enough that combat cancels it
const TP_COOLDOWN_TICKS: int = 7200 # 4 min ≈ a corner-to-corner walk on MEDIUM:
                                    # convenience, not a free shuttle
const WAYPOINT_RANGE: float = 64.0  # same feel as UpgradeDefs.MERCHANT_RANGE
const TP_MOVE_TOLERANCE: float = 2.0  # one move tick is ~4.7 px: any real step cancels

# Destination kinds (request_teleport wire payload).
const DEST_VILLAGE: int = 0
const DEST_MERCHANT: int = 1

# teleport_event codes. `data` = remaining cooldown ticks (authoritative state
# ships in every reply): TP_COOLDOWN_TICKS on COMPLETED, ready_tick - now on
# REJECT_COOLDOWN, 0 otherwise.
const EVENT_STARTED: int = 0
const EVENT_COMPLETED: int = 1
const EVENT_CANCELLED_MOVED: int = 2
const EVENT_CANCELLED_DAMAGED: int = 3
const EVENT_CANCELLED_DEAD: int = 4
const REJECT_COOLDOWN: int = 5
const REJECT_RANGE: int = 6
const REJECT_DENIED: int = 7
const REJECT_BUSY: int = 8
const REJECT_DEAD: int = 9

## A cast may START from within range of ANY waypoint anchor (village or
## merchant, all factions): travel is node-to-node, never a hearthstone out of
## combat in the field.
static func near_waypoint(g: WorldGeometry, pos: Vector2) -> bool:
	for v in g.villages:
		if pos.distance_to(v) <= WAYPOINT_RANGE:
			return true
	for m in g.merchants:
		if pos.distance_to(m) <= WAYPOINT_RANGE:
			return true
	return false

## Allowed DESTINATIONS: own-faction villages + neutral mid merchants. Enemy
## corners are unreachable by design (no TP spawn-camping), and the own corner
## merchant is excluded as redundant (it sits 3 tiles from the faction's first
## village).
static func can_teleport_to(g: WorldGeometry, faction: int, dest_kind: int, dest_index: int) -> bool:
	if faction < 1:
		return false
	if dest_kind == DEST_VILLAGE:
		return dest_index >= 0 and dest_index < g.villages.size() \
			and g.village_factions[dest_index] == faction
	if dest_kind == DEST_MERCHANT:
		return dest_index >= 0 and dest_index < g.merchants.size() \
			and g.merchant_faction(dest_index) == 0
	return false

static func dest_pos(g: WorldGeometry, dest_kind: int, dest_index: int) -> Vector2:
	if dest_kind == DEST_VILLAGE:
		return g.villages[dest_index]
	return g.merchants[dest_index]
