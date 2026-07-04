class_name ServerPlayer extends RefCounted
## Per-peer bookkeeping on the server. Minimal for now; the natural home for
## future per-connection state (display name, account id, measured latency, etc).

var peer_id: int
var entity_id: int
var appearance: int  # sanitized Appearance code, stamped onto the entity at spawn
var faction: int     # validated FactionDefs id (1..lobby faction_count)
var gems: int = 0    # per-lobby gem balance — SERVER-ONLY (never in snapshots);
                     # the client learns it via the reliable gems_event RPC
var teleport_ready_tick: int = 0  # absolute server tick the next waypoint travel is
                                  # allowed at. Full int (7200 ticks overflows the u8
                                  # ability_cds ceiling) — SERVER-ONLY, zero wire cost.
                                  # Deliberately NOT reset on death: no die-to-reset.

func _init(p_peer_id: int, p_entity_id: int, p_appearance: int, p_faction: int) -> void:
	peer_id = p_peer_id
	entity_id = p_entity_id
	appearance = p_appearance
	faction = p_faction
