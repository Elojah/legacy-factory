class_name InterpolationBuffer extends RefCounted
## Per-remote-entity history of authoritative states keyed by server tick.
## sample(render_tick) returns a smoothly interpolated state, so remote entities
## glide between sparse snapshots instead of teleporting each tick.

var _samples: Array = []  # [{tick:int, state:EntityState}] ascending by tick

func push(server_tick: int, state: EntityState) -> void:
	# Drop stale/duplicate ticks (unreliable_ordered already discards older).
	if not _samples.is_empty() and server_tick <= _samples[-1].tick:
		return
	_samples.append({"tick": server_tick, "state": state.clone()})
	while _samples.size() > NetConfig.INTERP_BUFFER_TICKS:
		_samples.pop_front()

func latest() -> EntityState:
	return _samples[-1].state if not _samples.is_empty() else null

func sample(render_tick: float) -> EntityState:
	if _samples.is_empty():
		return null
	if _samples.size() == 1 or render_tick <= float(_samples[0].tick):
		return _samples[0].state
	if render_tick >= float(_samples[-1].tick):
		return _samples[-1].state  # extrapolation not done here; hold newest
	for i in range(_samples.size() - 1):
		var a = _samples[i]
		var b = _samples[i + 1]
		if render_tick >= float(a.tick) and render_tick <= float(b.tick):
			var span := float(b.tick - a.tick)
			var t := 0.0 if span <= 0.0 else (render_tick - float(a.tick)) / span
			return _interp(a.state, b.state, t)
	return _samples[-1].state

func _interp(a: EntityState, b: EntityState, t: float) -> EntityState:
	# Discrete fields (hp, ability phase) taken from the newer sample; continuous
	# fields (pos, facing) interpolated for smoothness.
	var s := b.clone()
	s.pos = a.pos.lerp(b.pos, t)
	if a.facing.length() > 0.01 and b.facing.length() > 0.01:
		s.facing = a.facing.slerp(b.facing, t)
	return s
