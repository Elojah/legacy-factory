class_name EntityState extends RefCounted
## Plain data describing one simulated entity. This is what snapshots carry and
## what the deterministic sim mutates. No rendering, no nodes.

var id: int = 0
var kind: int = NetConfig.KIND_PLAYER
var pos: Vector2 = Vector2.ZERO
var vel: Vector2 = Vector2.ZERO
var facing: Vector2 = Vector2.DOWN
var hp: int = 100
# Ability state machine (see shared/combat/ability.gd + ability_defs.gd):
var ability_id: int = 0      # AbilityDefs.* — which ability is/was being cast
var ability_phase: int = 0   # Ability.PHASE_*
var ability_timer: int = 0   # ticks remaining in current phase (projectiles: TTL)
var ability_has_hit: bool = false  # effect already applied this active window
var ability_cds: PackedInt32Array = PackedInt32Array()  # per-slot cooldown ticks
var owner_id: int = 0        # projectiles: caster entity id (0 otherwise)
var last_input_seq: int = 0  # last input the server consumed (for reconciliation)
var appearance: int = 0      # Appearance-encoded look (visual only; sim never reads it)
var faction: int = 0         # FactionDefs id; 0 = none (non-players). SIM-READ (hostility)
var upgrades: int = 0        # UpgradeDefs u16 bitfield. SIM-READ (damage/cd/speed/hp
							 # scaling + NOVA/VOLLEY gates); projectiles carry their caster's
var last_hit_by: int = 0     # entity id of the last damage source (projectiles credit
							 # owner_id). NOT serialized: server-only read (kill credit)

func _init() -> void:
	ability_cds.resize(AbilityDefs.ABILITY_COUNT)  # zero-filled

func is_alive() -> bool:
	return hp > 0

func clone() -> EntityState:
	var e := EntityState.new()
	e.copy_from(self)
	return e

func copy_from(o: EntityState) -> void:
	id = o.id
	kind = o.kind
	pos = o.pos
	vel = o.vel
	facing = o.facing
	hp = o.hp
	ability_id = o.ability_id
	ability_phase = o.ability_phase
	ability_timer = o.ability_timer
	ability_has_hit = o.ability_has_hit
	# Packed arrays are COW references — duplicate so reconciliation replays
	# never mutate the snapshot's copy through aliasing.
	ability_cds = o.ability_cds.duplicate()
	owner_id = o.owner_id
	last_input_seq = o.last_input_seq
	appearance = o.appearance
	faction = o.faction
	upgrades = o.upgrades
	last_hit_by = o.last_hit_by

func write_into(buf: PackedByteArray) -> void:
	Serialization.w_u32(buf, id)
	Serialization.w_u8(buf, kind)
	Serialization.w_f32(buf, pos.x)
	Serialization.w_f32(buf, pos.y)
	Serialization.w_f32(buf, vel.x)
	Serialization.w_f32(buf, vel.y)
	Serialization.w_unit_vec(buf, facing)
	Serialization.w_u16(buf, maxi(0, hp))
	Serialization.w_u8(buf, ability_id)
	Serialization.w_u8(buf, ability_phase)
	Serialization.w_u8(buf, clampi(ability_timer, 0, 255))
	Serialization.w_u8(buf, 1 if ability_has_hit else 0)
	for i in AbilityDefs.ABILITY_COUNT:
		Serialization.w_u8(buf, clampi(ability_cds[i], 0, 255))
	Serialization.w_u32(buf, owner_id)
	Serialization.w_u32(buf, last_input_seq)
	Serialization.w_u16(buf, appearance & 0xFFFF)
	Serialization.w_u8(buf, faction & 0xFF)
	Serialization.w_u16(buf, upgrades & 0xFFFF)
	# last_hit_by intentionally NOT serialized — server-only kill credit.

static func read_from(r: Dictionary) -> EntityState:
	var e = EntityState.new()
	e.id = Serialization.r_u32(r)
	e.kind = Serialization.r_u8(r)
	e.pos = Vector2(Serialization.r_f32(r), Serialization.r_f32(r))
	e.vel = Vector2(Serialization.r_f32(r), Serialization.r_f32(r))
	e.facing = Serialization.r_unit_vec(r)
	if e.facing.length() > 0.001:
		e.facing = e.facing.normalized()
	else:
		e.facing = Vector2.DOWN
	e.hp = Serialization.r_u16(r)
	e.ability_id = Serialization.r_u8(r)
	e.ability_phase = Serialization.r_u8(r)
	e.ability_timer = Serialization.r_u8(r)
	e.ability_has_hit = Serialization.r_u8(r) != 0
	for i in AbilityDefs.ABILITY_COUNT:
		e.ability_cds[i] = Serialization.r_u8(r)
	e.owner_id = Serialization.r_u32(r)
	e.last_input_seq = Serialization.r_u32(r)
	e.appearance = Serialization.r_u16(r)
	e.faction = Serialization.r_u8(r)
	e.upgrades = Serialization.r_u16(r)
	return e
