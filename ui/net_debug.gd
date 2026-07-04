class_name NetDebug
## Static formatter for the F3 network-debug overlay. Keeping it stateless makes
## it easy to call from client_world each frame.

static func format(info: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("=== NET DEBUG (F3) ===")
	lines.append("synced:        %s" % str(info.get("synced", false)))
	lines.append("rtt:           %.0f ms" % float(info.get("rtt_ms", 0.0)))
	lines.append("est server tick:%.1f" % float(info.get("est_tick", 0.0)))
	lines.append("last snap tick: %d" % int(info.get("snap_tick", 0)))
	lines.append("render tick:    %.1f" % float(info.get("render_tick", 0.0)))
	lines.append("recon error:    %.2f px" % float(info.get("recon_err", 0.0)))
	lines.append("unacked inputs: %d" % int(info.get("unacked", 0)))
	lines.append("entities:       %d" % int(info.get("entities", 0)))
	return "\n".join(lines)
