class_name PredictionBuffer extends RefCounted
## Ring buffer of inputs the client has applied locally but the server may not
## have acknowledged yet. On reconciliation we drop acked inputs and replay the
## rest on top of the authoritative state.

var _entries: Array = []  # [{seq:int, cmd:InputCommand, state:EntityState}] oldest->newest

func record(cmd: InputCommand, state: EntityState) -> void:
	_entries.append({"seq": cmd.seq, "cmd": cmd, "state": state.clone()})
	while _entries.size() > NetConfig.INPUT_BUFFER_SIZE:
		_entries.pop_front()

## Drop everything the server has confirmed processing.
func ack(acked_seq: int) -> void:
	while not _entries.is_empty() and _entries[0].seq <= acked_seq:
		_entries.pop_front()

## Inputs still awaiting acknowledgement, oldest first — replayed during reconcile.
func remaining_cmds() -> Array:
	var out: Array = []
	for e in _entries:
		out.append(e.cmd)
	return out

## The newest n inputs, for loss-redundant packets.
func recent(n: int) -> Array:
	var out: Array = []
	var start := maxi(0, _entries.size() - n)
	for i in range(start, _entries.size()):
		out.append(_entries[i].cmd)
	return out

func size() -> int:
	return _entries.size()
