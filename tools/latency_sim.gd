class_name LatencySim extends RefCounted
## Application-layer network condition simulator for local testing.
## Instead of touching ENet, we delay/drop the DELIVERY of decoded messages by
## queueing the callable that would emit/process them. Used on clients only:
## delaying both outbound sends and inbound receives reproduces a realistic RTT.
## This is a TEST TOOL — randomness (randf) is fine here, unlike the shared sim.

var lag_ms: float = 0.0
var jitter_ms: float = 0.0
var loss: float = 0.0  # 0..1

var _queue: Array = []  # [{release: float, cb: Callable}]
var _rng := RandomNumberGenerator.new()

func enabled() -> bool:
	return lag_ms > 0.0 or jitter_ms > 0.0 or loss > 0.0

## Schedule `cb`. If disabled, runs immediately so there is zero overhead.
func submit(now_ms: float, cb: Callable) -> void:
	if not enabled():
		cb.call()
		return
	if loss > 0.0 and _rng.randf() < loss:
		return  # packet dropped
	var delay := maxf(0.0, lag_ms + _rng.randf_range(-jitter_ms, jitter_ms))
	_queue.append({"release": now_ms + delay, "cb": cb})

## Fire everything due by now. Call once per frame.
func drain(now_ms: float) -> void:
	if _queue.is_empty():
		return
	var pending: Array = []
	for item in _queue:
		if item.release <= now_ms:
			item.cb.call()
		else:
			pending.append(item)
	_queue = pending
