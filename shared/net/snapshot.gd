class_name Snapshot extends RefCounted
## A full world snapshot broadcast each tick over the unreliable channel.
## Per-player input acknowledgement travels inside each EntityState
## (last_input_seq), so the snapshot needs no per-recipient payload.

var server_tick: int = 0
var relations: int = 0    # the lobby's FactionDefs 2-bit pair table (latest wins)
var entities: Array = []  # Array[EntityState]

static func from_states(p_server_tick: int, states: Dictionary, p_relations: int) -> Snapshot:
	var s := Snapshot.new()
	s.server_tick = p_server_tick
	s.relations = p_relations
	var ids := states.keys()
	ids.sort()
	for id in ids:
		s.entities.append(states[id])
	return s

func to_bytes() -> PackedByteArray:
	var buf := PackedByteArray()
	Serialization.w_u32(buf, server_tick)
	Serialization.w_u16(buf, relations & 0xFFFF)
	Serialization.w_u16(buf, entities.size())
	for e in entities:
		e.write_into(buf)
	return buf

static func from_bytes(data: PackedByteArray) -> Snapshot:
	var r = Serialization.reader(data)
	var s = Snapshot.new()
	s.server_tick = Serialization.r_u32(r)
	s.relations = Serialization.r_u16(r)
	var n := Serialization.r_u16(r)
	for _i in n:
		s.entities.append(EntityState.read_from(r))
	return s
