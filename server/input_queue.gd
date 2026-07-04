class_name InputQueue extends RefCounted
## Per-peer ordered buffer of received InputCommands. Dedupes by seq, drops
## stale, and bounds latency: if the client gets ahead, we fast-forward by
## discarding the oldest queued inputs rather than letting lag accumulate.

const SOFT_CAP: int = 4  # max queued before we fast-forward to catch up

var _pending: Array = []           # InputCommands with seq > _last_processed_seq
var _last_processed_seq: int = -1
var _last_cmd: InputCommand = null

func push(cmds: Array) -> void:
	for c in cmds:
		if c.seq > _last_processed_seq and not _has_seq(c.seq):
			_pending.append(c)
	_pending.sort_custom(func(a, b): return a.seq < b.seq)

func _has_seq(seq: int) -> bool:
	for c in _pending:
		if c.seq == seq:
			return true
	return false

## Return the next input to simulate this tick, or null if we have nothing new
## (the sim treats null as "no input" -> the entity halts). Bounds latency by
## skipping ahead when the buffer is too deep.
func pop_next() -> InputCommand:
	while _pending.size() > SOFT_CAP:
		var dropped: InputCommand = _pending.pop_front()
		_last_processed_seq = dropped.seq
		_last_cmd = dropped
	if _pending.is_empty():
		return null
	var c: InputCommand = _pending.pop_front()
	_last_processed_seq = c.seq
	_last_cmd = c
	return c
