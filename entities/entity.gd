class_name GameEntity extends Node2D
## Visual shell for a simulated entity. Holds NO simulation logic — it renders
## whatever EntityState it is handed via apply_state(): a 4-direction
## AnimatedSprite2D body (idle/walk/attack, keyed off facing / velocity /
## ability_phase) plus a small procedural HP bar. Sprite frames are shared per
## look (kind + appearance) via CharSpriteFrames. The sim still uses the analog EntityState.facing;
## the cardinal snap here is cosmetic only and never feeds back into the sim.

signal effect_requested(effect_id: int, world_pos: Vector2, facing: Vector2)

const MODE_REMOTE: int = 0   # interpolated from snapshots
const MODE_LOCAL: int = 1    # client-predicted (the owning player)
const MOVE_EPS: float = 4.0  # px/s below which we show idle rather than walk

var state: EntityState = EntityState.new()
var mode: int = MODE_REMOTE
var max_hp: int = NetConfig.PLAYER_MAX_HP

var _sprite: AnimatedSprite2D
var _prev_phase: int = Ability.PHASE_IDLE
var _flash: float = 0.0      # hit-flash intensity, decays in _process
var _last_hp: int = -1       # object-identity-safe hp tracking (local player
							 # apply_state receives the SAME predicted_state ref)
const FLASH_COLOR := Color(1.0, 0.5, 0.45)

func setup(initial: EntityState, p_mode: int) -> void:
	state = initial
	mode = p_mode
	max_hp = EntityDefs.max_hp_of(state)  # per-entity: VIGOR players show /125
	_sprite = $Sprite
	var species := 0
	if state.kind == NetConfig.KIND_MONSTER:
		# Cosmetic species from the island biome (deterministic on every client).
		species = MonsterSkins.species_for(state)
	_sprite.sprite_frames = CharSpriteFrames.get_for(state.kind, state.appearance, species)
	if state.kind == NetConfig.KIND_BOSS:
		# Bespoke 64x64 kit sheet; re-anchor so the frame bottom wraps the 28px
		# collider. Sprite-only offset keeps _draw geometry in node space.
		_sprite.offset = Vector2(0, -20)
	_prev_phase = state.ability_phase
	global_position = state.pos
	_update_anim()
	queue_redraw()

func apply_state(s: EntityState) -> void:
	state = s
	global_position = s.pos
	# Hit flash on any hp DECREASE (tracked as a plain int — safe against the
	# local player passing the same EntityState instance every tick).
	if _last_hp >= 0 and s.hp < _last_hp and s.is_alive():
		_flash = 1.0
	_last_hp = s.hp
	_update_anim()
	queue_redraw()

func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - 6.0 * delta)
		if _sprite != null:
			_sprite.modulate = _tint().lerp(FLASH_COLOR, _flash)

# --- animation ---------------------------------------------------------------
func _update_anim() -> void:
	if _sprite == null:
		return
	var face := CharAnim.dir_from_facing(state.facing)
	_sprite.flip_h = (face == CharAnim.FACE_LEFT)
	_sprite.modulate = _tint().lerp(FLASH_COLOR, _flash)

	var anim := _target_anim(face)
	if _sprite.animation != anim:
		_sprite.play(anim)
	if not state.is_alive():
		# Freeze on the first frame so corpses don't keep stepping.
		_sprite.stop()
		_sprite.frame = 0

	# Fire cast FX once, on the entered-ACTIVE edge (when the effect goes live).
	# "!= ACTIVE" (not "== WINDUP") because dash has a 0-tick windup and can jump
	# IDLE->ACTIVE within one applied state. Gating on the previous phase keeps
	# reconciliation replays from re-firing it.
	var dir := state.facing.normalized() if state.facing.length() > 0.01 else Vector2.DOWN
	# Charge dust fires on the WINDUP edge — the warning IS the payoff there.
	if state.is_alive() and state.ability_phase == Ability.PHASE_WINDUP \
			and _prev_phase != Ability.PHASE_WINDUP and state.ability_id == AbilityDefs.BOSS_CHARGE:
		effect_requested.emit(EffectIds.BOSS_CHARGE_DUST, global_position, dir)
	if state.is_alive() and state.ability_phase == Ability.PHASE_ACTIVE and _prev_phase != Ability.PHASE_ACTIVE:
		match state.ability_id:
			AbilityDefs.MELEE:
				var origin := global_position + dir * (NetConfig.ENTITY_RADIUS + AbilityDefs.MELEE_RANGE * 0.5)
				effect_requested.emit(EffectIds.SLASH, origin, dir)
			AbilityDefs.DASH:
				effect_requested.emit(EffectIds.DASH_PUFF, global_position, dir)
			AbilityDefs.HEAL:
				effect_requested.emit(EffectIds.HEAL_SPARKLE, global_position, dir)
			AbilityDefs.SLAM:
				effect_requested.emit(EffectIds.SLAM_RING, global_position, dir)
			AbilityDefs.BOLT, AbilityDefs.VOLLEY:
				effect_requested.emit(EffectIds.MUZZLE_FLASH, global_position + dir * (NetConfig.ENTITY_RADIUS + 4.0), dir)
			AbilityDefs.BOSS_SMASH:
				effect_requested.emit(EffectIds.BOSS_SMASH_RING, global_position, dir)
			AbilityDefs.BOSS_SUMMON:
				effect_requested.emit(EffectIds.BOSS_SUMMON_BURST, global_position, dir)
			AbilityDefs.NOVA:
				effect_requested.emit(EffectIds.NOVA_RING, global_position, dir)
			# BOSS_BARRAGE/HAZARD: the spawned shards/zones are the FX.
	_prev_phase = state.ability_phase

func _target_anim(face: int) -> String:
	if state.is_alive() and state.ability_phase != Ability.PHASE_IDLE:
		return CharAnim.name_for("attack", face)
	if state.is_alive() and state.vel.length() > MOVE_EPS:
		return CharAnim.name_for("walk", face)
	return CharAnim.name_for("idle", face)

func _tint() -> Color:
	if not state.is_alive():
		return Color(0.4, 0.4, 0.45)
	if state.kind == NetConfig.KIND_BOSS:
		# Kit identity is baked into the bespoke sheet now; only the danger tier
		# tints (same warm shift as monsters, subtler — the sheet stays readable).
		var btier := UpgradeDefs.npc_tier(state.upgrades)
		if btier > 0:
			return Color(1, 1, 1).lerp(Color(1.0, 0.4, 0.35), 0.06 * float(btier))
		return Color.WHITE
	if state.kind == NetConfig.KIND_PLAYER and state.faction > 0:
		# Faction identity — local AND remote, so you can read your own allegiance.
		return FactionPalette.color_for(state.faction).lerp(Color.WHITE, 0.55)
	if state.kind == NetConfig.KIND_PLAYER and mode == MODE_REMOTE:
		return Color(0.85, 0.97, 0.92)  # cooler cast distinguishes other players
	if state.kind == NetConfig.KIND_MONSTER:
		# Danger tier (upgrades bits 0-1, on the wire for every entity): higher
		# tiers read angrier the closer the island sits to the map center.
		var tier := UpgradeDefs.npc_tier(state.upgrades)
		if tier > 0:
			return Color(1, 1, 1).lerp(Color(1.0, 0.35, 0.30), 0.12 * float(tier))
	return Color(1, 1, 1)

# --- HP bar + boss telegraphs (kept procedural) --------------------------------
func _draw() -> void:
	if not state.is_alive():
		return
	_draw_telegraph()
	var w := 20.0
	var h := 3.0
	var y := -34.0  # above the 24x32 frame (sprite offset -12 puts its top at -28)
	if state.kind == NetConfig.KIND_BOSS:
		w = 72.0
		h = 6.0
		y = -60.0  # above the 64x64 kit sprite (offset -20 puts its top at -52)
	var frac := clampf(float(state.hp) / float(max_hp), 0.0, 1.0)
	draw_rect(Rect2(-w * 0.5, y, w, h), Color(0, 0, 0, 0.6))
	var fill := UiPalette.OK if frac > 0.3 else UiPalette.DANGER
	draw_rect(Rect2(-w * 0.5, y, w * frac, h), fill)
	# Faction strip under the hp bar — friend/foe stays readable even where the
	# body tint is ambiguous (players only; monsters/bosses have faction 0).
	if state.kind == NetConfig.KIND_PLAYER and state.faction > 0:
		draw_rect(Rect2(-w * 0.5, y + h + 1.0, w, 2.0), FactionPalette.color_for(state.faction))

## Boss windup telegraphs: cosmetic warnings drawn purely from replicated fields
## (ability_id/timer/facing) — bosses are always remote/interpolated, and nothing
## here feeds back into the sim. The danger area fills in as the windup runs out.
func _draw_telegraph() -> void:
	if state.kind != NetConfig.KIND_BOSS or state.ability_phase != Ability.PHASE_WINDUP:
		return
	var aid := state.ability_id
	var wind := maxi(AbilityDefs.WINDUP_TICKS[aid], 1)
	var p := 1.0 - clampf(float(state.ability_timer) / float(wind), 0.0, 1.0)
	var col := BossPalette.color_for(state.appearance)
	var warn := Color(col.r, col.g, col.b, 0.20 + 0.15 * p)
	var dir := state.facing.normalized() if state.facing.length() > 0.01 else Vector2.DOWN
	match aid:
		AbilityDefs.BOSS_SMASH:
			draw_circle(Vector2.ZERO, AbilityDefs.SMASH_RADIUS * p, warn)
			draw_arc(Vector2.ZERO, AbilityDefs.SMASH_RADIUS, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.8), 2.0)
		AbilityDefs.BOSS_BARRAGE:
			for i in AbilityDefs.BARRAGE_COUNT:
				var d := dir.rotated(TAU * float(i) / float(AbilityDefs.BARRAGE_COUNT))
				draw_line(d * 20.0, d * (40.0 + 60.0 * p), Color(col.r, col.g, col.b, 0.5 + 0.3 * p), 2.0)
		AbilityDefs.BOSS_CHARGE:
			var reach := AbilityDefs.CHARGE_SPEED * NetConfig.DT * float(AbilityDefs.ACTIVE_TICKS[AbilityDefs.BOSS_CHARGE])
			var n := dir.orthogonal() * AbilityDefs.CHARGE_IMPACT_RADIUS * 0.5
			# draw_primitive: the polygon triangulator can fail at huge world coords.
			draw_primitive(PackedVector2Array([-n, dir * reach - n, dir * reach + n]),
				PackedColorArray([warn, warn, warn]), PackedVector2Array())
			draw_primitive(PackedVector2Array([-n, dir * reach + n, n]),
				PackedColorArray([warn, warn, warn]), PackedVector2Array())
			draw_circle(dir * reach, AbilityDefs.CHARGE_IMPACT_RADIUS, Color(col.r, col.g, col.b, 0.15 + 0.2 * p))
		AbilityDefs.BOSS_SUMMON:
			draw_arc(Vector2.ZERO, NetConfig.BOSS_RADIUS + 24.0, 0.0, TAU * p, 40, Color(col.r, col.g, col.b, 0.8), 2.5)
		AbilityDefs.BOSS_HAZARD:
			draw_arc(Vector2.ZERO, AbilityDefs.HAZARD_RADIUS * (0.5 + 0.5 * p), 0.0, TAU, 32, Color(col.r, col.g, col.b, 0.6), 2.0)
