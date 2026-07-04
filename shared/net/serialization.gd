class_name Serialization
## Static (de)serialization helpers shared by client & server. Built on
## PackedByteArray encode/decode (a built-in Variant type) rather than
## StreamPeerBuffer: instantiating a native RefCounted class via .new() inside a
## multiplayer-RPC-invoked frame trips a GDScript 4.7 type-resolution bug, so we
## avoid native-class construction on the receive path entirely.
##
## Reads use a cursor Dictionary {buf, off} so callers can thread an offset
## without constructing any object.

# --- quantization -------------------------------------------------------------
## Map a unit-range float [-1, 1] to a signed byte [-127, 127].
static func quantize_unit(v: float) -> int:
	return clampi(int(roundf(v * 127.0)), -127, 127)

static func dequantize_unit(i: int) -> float:
	return float(i) / 127.0

## Quantize then dequantize so the sender can store exactly what the receiver
## will reconstruct (prediction must use the post-wire value).
static func requantize(v: float) -> float:
	return dequantize_unit(quantize_unit(v))

# --- writers (append to a PackedByteArray) ------------------------------------
static func w_u8(buf: PackedByteArray, v: int) -> void:
	buf.append(v & 0xFF)

static func w_s8(buf: PackedByteArray, v: int) -> void:
	buf.append(v & 0xFF)  # two's-complement low byte

static func w_u16(buf: PackedByteArray, v: int) -> void:
	buf.append(v & 0xFF)
	buf.append((v >> 8) & 0xFF)

static func w_u32(buf: PackedByteArray, v: int) -> void:
	buf.append(v & 0xFF)
	buf.append((v >> 8) & 0xFF)
	buf.append((v >> 16) & 0xFF)
	buf.append((v >> 24) & 0xFF)

static func w_f32(buf: PackedByteArray, v: float) -> void:
	var start := buf.size()
	buf.resize(start + 4)
	buf.encode_float(start, v)

static func w_unit_vec(buf: PackedByteArray, v: Vector2) -> void:
	w_s8(buf, quantize_unit(v.x))
	w_s8(buf, quantize_unit(v.y))

# --- reader (cursor over a PackedByteArray) -----------------------------------
static func reader(data: PackedByteArray) -> Dictionary:
	return {"buf": data, "off": 0}

static func r_u8(r: Dictionary) -> int:
	var v: int = r.buf.decode_u8(r.off)
	r.off += 1
	return v

static func r_s8(r: Dictionary) -> int:
	var v: int = r.buf.decode_s8(r.off)
	r.off += 1
	return v

static func r_u16(r: Dictionary) -> int:
	var v: int = r.buf.decode_u16(r.off)
	r.off += 2
	return v

static func r_u32(r: Dictionary) -> int:
	var v: int = r.buf.decode_u32(r.off)
	r.off += 4
	return v

static func r_f32(r: Dictionary) -> float:
	var v: float = r.buf.decode_float(r.off)
	r.off += 4
	return v

static func r_unit_vec(r: Dictionary) -> Vector2:
	return Vector2(dequantize_unit(r_s8(r)), dequantize_unit(r_s8(r)))
