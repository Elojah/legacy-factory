class_name InputCommand extends RefCounted
## A single tick of player (or AI) intent. The ONLY thing clients send about
## their player — never positions. Created already-quantized so the predicting
## client uses the identical move vector the server will reconstruct.

var seq: int = 0          # client-monotonic sequence number (for ack/reconcile)
var tick: int = 0         # client's estimate of the server tick this is for
var move: Vector2 = Vector2.ZERO  # quantized unit-ish vector, length <= ~1
var buttons: int = 0      # bitmask: NetConfig.BTN_*

static func create(p_seq: int, p_tick: int, raw_move: Vector2, p_buttons: int) -> InputCommand:
	var c := InputCommand.new()
	c.seq = p_seq
	c.tick = p_tick
	# Store the post-wire value so prediction == server reconstruction.
	c.move = Vector2(Serialization.requantize(raw_move.x), Serialization.requantize(raw_move.y))
	c.buttons = p_buttons
	return c

func write_into(buf: PackedByteArray) -> void:
	Serialization.w_u32(buf, seq)
	Serialization.w_u32(buf, tick)
	Serialization.w_unit_vec(buf, move)
	Serialization.w_u8(buf, buttons)

static func read_from(r: Dictionary) -> InputCommand:
	var c = InputCommand.new()
	c.seq = Serialization.r_u32(r)
	c.tick = Serialization.r_u32(r)
	c.move = Serialization.r_unit_vec(r)
	c.buttons = Serialization.r_u8(r)
	return c

## Pack a batch (newest-last) into one packet for loss redundancy.
static func pack_batch(cmds: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	Serialization.w_u8(buf, cmds.size())
	for c in cmds:
		c.write_into(buf)
	return buf

static func unpack_batch(data: PackedByteArray) -> Array:
	var r = Serialization.reader(data)
	var out: Array = []
	var n := Serialization.r_u8(r)
	for _i in n:
		out.append(InputCommand.read_from(r))
	return out
