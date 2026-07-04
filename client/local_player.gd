class_name LocalPlayer
## Stateless helper that turns device input into a deterministic InputCommand.
## The command is created already-quantized so prediction uses the exact value
## the server will reconstruct from the wire.

static func capture_input(seq: int, tick: int) -> InputCommand:
	# get_vector returns x = right-left, y = down-up (matches screen-space).
	var move := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var buttons := 0
	if Input.is_action_pressed("attack") or Input.is_action_pressed("ability_1"):
		buttons |= NetConfig.BTN_ATTACK
	if Input.is_action_pressed("interact"):
		buttons |= NetConfig.BTN_INTERACT
	if Input.is_action_pressed("ability_2"):
		buttons |= NetConfig.BTN_BOLT
	if Input.is_action_pressed("ability_3"):
		buttons |= NetConfig.BTN_DASH
	if Input.is_action_pressed("ability_4"):
		buttons |= NetConfig.BTN_HEAL
	if Input.is_action_pressed("ability_5"):
		buttons |= NetConfig.BTN_SLAM
	# Merchant-unlockables: sent regardless of ownership — the shared sim ladder
	# ignores the bit without the unlock flag, identically on both ends.
	if Input.is_action_pressed("ability_6"):
		buttons |= NetConfig.BTN_NOVA
	if Input.is_action_pressed("ability_7"):
		buttons |= NetConfig.BTN_VOLLEY
	return InputCommand.create(seq, tick, move, buttons)
