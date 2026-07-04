extends Node
## GameClock — owns tick time on both ends.
## Server: `current_tick` is authoritative, incremented once per fixed step.
## Client: estimates the server's "now" tick from ping/pong RTT so it can stamp
## inputs and sample interpolation in the past. Time.get_ticks_msec() is used
## only for RTT/anchoring (a measurement) — never for simulation math.

var current_tick: int = 0          # server authoritative tick
var rtt_ms: float = 0.0            # smoothed round-trip time

var _synced: bool = false
var _anchor_server_tick: float = 0.0  # estimated server tick at the anchor moment
var _anchor_local_ms: float = 0.0     # local clock at the anchor moment

func now_ms() -> float:
	return float(Time.get_ticks_msec())

# --- server ---
func server_advance() -> void:
	current_tick += 1

# --- client clock sync ---
func note_pong(client_send_ms: float, server_tick: int) -> void:
	var now := now_ms()
	var rtt := now - client_send_ms
	rtt_ms = rtt if not _synced else lerpf(rtt_ms, rtt, NetConfig.CLOCK_SMOOTHING)
	# Where the server "is" at the moment we received this reply.
	var one_way_ticks := (rtt_ms * 0.5 / 1000.0) * float(NetConfig.TICK_RATE)
	var measured := float(server_tick) + one_way_ticks
	if not _synced:
		_anchor_server_tick = measured
		_anchor_local_ms = now
		_synced = true
	else:
		var predicted := _tick_at(now)
		_anchor_server_tick = lerpf(predicted, measured, NetConfig.CLOCK_SMOOTHING)
		_anchor_local_ms = now

func _tick_at(t_ms: float) -> float:
	return _anchor_server_tick + (t_ms - _anchor_local_ms) / 1000.0 * float(NetConfig.TICK_RATE)

func get_estimated_server_tick() -> float:
	return _tick_at(now_ms())

## The tick we render remote entities at: a little in the past for interpolation.
func get_render_tick() -> float:
	return get_estimated_server_tick() - float(NetConfig.INTERP_DELAY_TICKS)

func is_synced() -> bool:
	return _synced
