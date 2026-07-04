class_name UpgradeDefs
## Gem economy + skill customization: the packing of EntityState.upgrades (u16,
## SIM-READ), merchant item catalogue, costs and the scaled-value helpers the
## sim reads. Static consts + pure static funcs only (no autoload calls) so
## --script tools can depend on it — same discipline as FactionDefs. Gems
## themselves are SERVER-ONLY state (ServerPlayer.gems); only the upgrades
## bitfield rides the wire, because only it is read by WorldSim.

# --- EntityState.upgrades u16 bit layout ---------------------------------------
# bits 0-9   five 2-bit levels (0..3) for the base skills; bit pair = aid * 2
#            (MELEE 0-1, BOLT 2-3, DASH 4-5, HEAL 6-7, SLAM 8-9)
# bit 10     NOVA unlocked          bit 11  VOLLEY unlocked
# bit 12     passive VIGOR (+max hp)
# bit 13     passive SWIFT (+move speed)
# bit 14     passive FOCUS (-cooldowns)
# bit 15     reserved (always 0)
const MAX_SKILL_LEVEL: int = 3
const BIT_NOVA: int = 1 << 10
const BIT_VOLLEY: int = 1 << 11
const BIT_VIGOR: int = 1 << 12
const BIT_SWIFT: int = 1 << 13
const BIT_FOCUS: int = 1 << 14
const UPGRADES_MASK: int = 0x7FFF   # bit 15 reserved

# --- Merchant item ids (shop_purchase wire payload) -----------------------------
# 0..4 upgrade one level of the matching base skill (item id == ability id).
const ITEM_UP_MELEE: int = 0
const ITEM_UP_BOLT: int = 1
const ITEM_UP_DASH: int = 2
const ITEM_UP_HEAL: int = 3
const ITEM_UP_SLAM: int = 4
const ITEM_SKILL_NOVA: int = 5
const ITEM_SKILL_VOLLEY: int = 6
const ITEM_PASSIVE_VIGOR: int = 7
const ITEM_PASSIVE_SWIFT: int = 8
const ITEM_PASSIVE_FOCUS: int = 9
const ITEM_COUNT: int = 10

# --- gems_event reason codes (wire) ---------------------------------------------
const GEMS_AWARD_BOSS: int = 0
const GEMS_PURCHASE_OK: int = 1
const GEMS_REJECT_RANGE: int = 2
const GEMS_REJECT_FUNDS: int = 3
const GEMS_REJECT_MAXED: int = 4
const GEMS_REJECT_INVALID: int = 5
const GEMS_REJECT_DEAD: int = 6
const GEMS_GRANT: int = 7     # dev/test seed (--grant-gems), server-operator only
const GEMS_AWARD_MONSTER: int = 8     # tier-scaled last-hitter payout on a monster kill
const GEMS_AWARD_ORB: int = 9         # walk-over resource orb pickup (tier-scaled)
const GEMS_AWARD_CACHE: int = 10      # secret cache on a shortcut bridge (tier-scaled)
const GEMS_AWARD_SHRINE: int = 11     # faction-wide shrine capture payout (tier-scaled)

# --- Tuning ----------------------------------------------------------------------
## Boss payout per faction member, indexed by the boss's danger tier (npc_tier).
## Tier 2 == the historical flat GEM_AWARD_BOSS = 10.
const GEM_AWARD_BOSS_BY_TIER: Array[int] = [4, 6, 10, 16]
const GEM_AWARD_MONSTER_BASE: int = 1 # monster kill pays (tier + 1) * BASE to the last-hitter
const GEM_AWARD_BOSS: int = 10        # legacy flat value (== BY_TIER[2]); kept for reference
const MERCHANT_RANGE: float = 64.0    # buy distance from a village merchant
## Walk-over pickups (server detects proximity on its tick — no input bit needed).
## Deeper = richer: values by the point's danger tier. Respawn timers are full-int
## SERVER ticks (lobby dicts), never u8 wire fields.
const GEM_AWARD_ORB_BY_TIER: Array[int] = [1, 2, 3, 5]
const GEM_AWARD_CACHE_BY_TIER: Array[int] = [2, 3, 5, 8]   # above orbs: rewards route knowledge
const ORB_PICKUP_RANGE: float = 20.0  # walk-over feel (orb halo 6 px + entity radius 8)
const ORB_RESPAWN_TICKS: int = 3600   # 2 min: exploring onward beats camping one island
const CACHE_RESPAWN_TICKS: int = 9000 # 5 min: secrets feel rare
## Shrine capture (co-op): >= SHRINE_MIN_PLAYERS same-faction players channel inside
## SHRINE_RADIUS for SHRINE_CHANNEL_TICKS -> faction-wide payout, then a lockout.
const SHRINE_RADIUS: float = 48.0
const SHRINE_MIN_PLAYERS: int = 2
const SHRINE_CHANNEL_TICKS: int = 600     # 20 s — long enough for the island to fight back
const SHRINE_LOCKOUT_TICKS: int = 18000   # 10 min — no shrine-carousel farming
const GEM_AWARD_SHRINE_BY_TIER: Array[int] = [0, 3, 6, 10]  # tier >= 1 field islands only
const COST_SKILL_LEVEL_BASE: int = 5  # level N costs 5*N (5/10/15)
const COST_SKILL_UNLOCK: int = 25     # NOVA / VOLLEY
const COST_PASSIVE: int = 15
const SCALE_PCT_PER_LEVEL: int = 15   # +15% damage/heal per level (integer math)
const DASH_CD_PCT_PER_LEVEL: int = 15 # dash has no damage: its levels cut cooldown
const VIGOR_BONUS_HP: int = 25
const SWIFT_SPEED_MULT: float = 1.12  # const float multiply — identical on both ends
const FOCUS_CD_NUM: int = 90          # -10% on every player-ability cooldown
const FOCUS_CD_DEN: int = 100

# --- NPC danger tier ----------------------------------------------------------------
## Monsters/bosses carry their danger tier (0..3) in upgrades bits 0-1 —
## INTENTIONALLY aliasing the MELEE skill-level pair: NPCs never shop (no writer
## conflict) and monster melee then scales +15%/tier through damage_for with zero
## sim change. Max hp reads the tier via EntityDefs; the client reads it for
## cosmetics. Bosses never cast MELEE, so their tier bits only drive hp + award.
static func npc_tier(upgrades: int) -> int:
	return upgrades & 0x3

static func npc_tier_pack(tier: int) -> int:
	return clampi(tier, 0, 3)

## Faction-wide payout for a boss kill, keyed off the dead boss's tier bits.
static func boss_award_for(upgrades: int) -> int:
	return GEM_AWARD_BOSS_BY_TIER[npc_tier(upgrades)]

## Last-hitter payout for a plain monster kill (minions pay nothing — the caller
## filters them, or boss summon cycles would be a gem farm).
static func monster_award_for(upgrades: int) -> int:
	return (npc_tier(upgrades) + 1) * GEM_AWARD_MONSTER_BASE

# --- Bitfield accessors ------------------------------------------------------------
static func skill_level(upgrades: int, aid: int) -> int:
	if aid < AbilityDefs.MELEE or aid > AbilityDefs.SLAM:
		return 0
	return (upgrades >> (aid * 2)) & 0x3

## Whether this entity may cast `aid`. Base skills are always owned; NOVA/VOLLEY
## need their unlock bit. Gates the WorldSim button ladder on BOTH ends.
static func has_skill(upgrades: int, aid: int) -> bool:
	if aid == AbilityDefs.NOVA:
		return (upgrades & BIT_NOVA) != 0
	if aid == AbilityDefs.VOLLEY:
		return (upgrades & BIT_VOLLEY) != 0
	return true

static func has_passive(upgrades: int, bit: int) -> bool:
	return (upgrades & bit) != 0

# --- Scaled values read by the deterministic sim -----------------------------------
## `base * (100 + 15*level) / 100` — integer division on purpose (deterministic).
static func _scaled_up(base: int, level: int) -> int:
	@warning_ignore("integer_division")
	return base * (100 + SCALE_PCT_PER_LEVEL * level) / 100

## Direct-hit damage for the caster's `upgrades`. Only the leveled base skills
## scale; everything else (boss pool, NOVA) passes through its AbilityDefs base,
## so entities with upgrades == 0 (monsters/bosses) are untouched by construction.
static func damage_for(aid: int, upgrades: int) -> int:
	match aid:
		AbilityDefs.MELEE:
			return _scaled_up(AbilityDefs.MELEE_DAMAGE, skill_level(upgrades, aid))
		AbilityDefs.SLAM:
			return _scaled_up(AbilityDefs.SLAM_DAMAGE, skill_level(upgrades, aid))
		AbilityDefs.NOVA:
			return AbilityDefs.NOVA_DAMAGE
		_:
			return 0

## Heal amount for the caster's `upgrades` (40 -> 46/52/58).
static func heal_for(upgrades: int) -> int:
	return _scaled_up(AbilityDefs.HEAL_AMOUNT, skill_level(upgrades, AbilityDefs.HEAL))

## Damage a projectile deals, keyed off the ability id + the CASTER's upgrades
## stamped on it at spawn (replaces AbilityDefs.projectile_damage).
static func projectile_damage_for(aid: int, upgrades: int) -> int:
	if aid == AbilityDefs.BOSS_BARRAGE:
		return AbilityDefs.BARRAGE_DAMAGE
	if aid == AbilityDefs.VOLLEY:
		return AbilityDefs.VOLLEY_DAMAGE
	return _scaled_up(AbilityDefs.BOLT_DAMAGE, skill_level(upgrades, AbilityDefs.BOLT))

## Cooldown written when a cast completes. Only ever REDUCES the AbilityDefs
## base, so the u8 wire ceiling (<= 255) holds by construction.
static func cooldown_for(aid: int, upgrades: int) -> int:
	var cd: int = AbilityDefs.COOLDOWN_TICKS[aid]
	if aid == AbilityDefs.DASH:
		@warning_ignore("integer_division")
		cd = cd * (100 - DASH_CD_PCT_PER_LEVEL * skill_level(upgrades, aid)) / 100
	if has_passive(upgrades, BIT_FOCUS) and aid in AbilityDefs.PLAYER_ABILITIES:
		@warning_ignore("integer_division")
		cd = cd * FOCUS_CD_NUM / FOCUS_CD_DEN
	return cd

static func max_hp_bonus(upgrades: int) -> int:
	return VIGOR_BONUS_HP if has_passive(upgrades, BIT_VIGOR) else 0

# --- Merchant catalogue -------------------------------------------------------------
## Whether the item can still be bought (level not maxed / bit not owned).
static func item_available(item_id: int, upgrades: int) -> bool:
	if item_id >= ITEM_UP_MELEE and item_id <= ITEM_UP_SLAM:
		return skill_level(upgrades, item_id) < MAX_SKILL_LEVEL
	var bit := _item_bit(item_id)
	return bit != 0 and (upgrades & bit) == 0

## Gem cost of the NEXT purchase of this item given current `upgrades`.
static func item_cost(item_id: int, upgrades: int) -> int:
	if item_id >= ITEM_UP_MELEE and item_id <= ITEM_UP_SLAM:
		return COST_SKILL_LEVEL_BASE * (skill_level(upgrades, item_id) + 1)
	if item_id == ITEM_SKILL_NOVA or item_id == ITEM_SKILL_VOLLEY:
		return COST_SKILL_UNLOCK
	return COST_PASSIVE

## Returns the new packed value after buying `item_id` (caller validates first;
## an unavailable item is returned unchanged as defense in depth).
static func apply_item(upgrades: int, item_id: int) -> int:
	if not item_available(item_id, upgrades):
		return upgrades
	if item_id >= ITEM_UP_MELEE and item_id <= ITEM_UP_SLAM:
		var lv := skill_level(upgrades, item_id)
		return (upgrades & ~(0x3 << (item_id * 2))) | ((lv + 1) << (item_id * 2))
	return upgrades | _item_bit(item_id)

## The single unlock/passive bit an item sets (0 for the leveled skill items).
static func _item_bit(item_id: int) -> int:
	match item_id:
		ITEM_SKILL_NOVA:
			return BIT_NOVA
		ITEM_SKILL_VOLLEY:
			return BIT_VOLLEY
		ITEM_PASSIVE_VIGOR:
			return BIT_VIGOR
		ITEM_PASSIVE_SWIFT:
			return BIT_SWIFT
		ITEM_PASSIVE_FOCUS:
			return BIT_FOCUS
	return 0
