# Legacy Factory — Agent Rules

Online 2D RPG, Golden-Sun-style top-down. **Godot 4.7, GDScript only.**
An authoritative dedicated server and clients run the **same project**; the role is
chosen at runtime. Combat netcode follows the Gabriel-Gambetta model:
**client-side prediction + server reconciliation + entity interpolation.**

State synchronization is the #1 priority of this codebase. When in doubt, favor
correctness of sync and authority over convenience.

---

## Golden rules (non-negotiable)

- **The server is the single source of truth.** Never trust the client for
  position, velocity, HP, damage, or whether an ability succeeded. Clients send
  **inputs only** (`InputCommand`); the server decides everything else.
- **Clients predict, the server validates, snapshots reconcile.** If the client
  and server disagree, the server wins — always.
- **Shared simulation must be deterministic.** Code in `shared/` must produce
  identical results from identical inputs on every machine. No `Input`, no
  rendering, no `randf()` (use a seeded RNG if randomness is ever needed), no
  wall-clock time for math — use the fixed `NetConfig.DT`. The same
  `WorldSim.step()` runs on both client (prediction) and server (authority).

---

## Architecture map

```
autoload/   NetConfig (consts) · GameClock (tick/clock-sync) · NetManager (all RPCs) · Session (client lobby state) · Bootstrap (role+boot+lobby flow)
shared/     deterministic sim, imported by BOTH ends — the netcode contract
  sim/      world_sim · entity_state · input_command · movement · entity_defs (per-kind radius/max-hp/roles + NPC tier hp tables) · faction_defs (faction ids + 2-bit pair relations + hostility rules) · teleport_defs (waypoint-travel tuning/wire codes + the shared destination rules) · world_geometry · world_generator (seeded procgen: corner faction starts, center-out danger tiers, orb tiers + shortcut-bridge caches)
  combat/   ability (one phase machine, per-slot cooldowns) · ability_defs (5 base skills + 5-ability boss pool + 2 merchant-unlockables + tick tuning) · upgrade_defs (gem economy: u16 upgrades packing, item catalogue/costs, scaled damage/heal/cd helpers) · boss_defs (kits/phases/patterns/policy) · hitbox_resolver (cone + radius)
  net/      serialization · snapshot · appearance (u16 character-look spec: class/hair/skin, server-sanitized)
client/     client_world (predict/reconcile/interp + day/night tint driver) · local_player · prediction_buffer · interpolation_buffer · char_painter (runtime sheet baker — THE sheet-contract authority: 24x32 frames, 12 cols) · char_sprite_frames (per-look cache + species/boss sheets) · char_anim · monster_skins (biome→species pick) · palette_util (hue-shifted color ramps for ALL baked art) · boss_palette (kit colors) · faction_palette (faction names/colors) · effect_spawner (data-driven FX registry + shared frame caches) · ui_palette/ui_theme (runtime pixel-font Theme)
server/     server_world (LOBBY MANAGER) · lobby (one authoritative world each) · input_queue · ai_controller · boss_ai (kit/phase pattern driver) · server_player
entities/   player/monster/projectile/hazard scenes — VISUAL SHELLS only (apply_state); effects/sheet_effect (the one generic one-shot FX node)
scenes/     bootstrap (main) · main_menu · character_creator · lobby_browser · server_root · client_root (WorldTint CanvasModulate + y-sorted Playfield holding Trees+Entities)
world/      test_map (renders a WorldGeometry) · floor_renderer (tiling biome floors: 4-variant patchwork + edge fringe + AO + floating-island undersides w/ reverse-pyramid stones) · water_renderer + water_layer (animated ponds w/ soft banks + waterfalls) · foliage + foliage_layer (swaying grass batch + per-instance y-sortable tree sprites + rock/decal batch) · glow_layer (additive night-scaled glows: orbs/runes/shrines/banners/lava/windows) · sky (day/night shader) · biome_registry · map_markers (villages/merchant stalls/waypoint obelisks/tier-tinted orbs/cache glints/shrine monoliths/boss banners + taken-pickup state)
ui/         hud (+toasts, gems readout) · hotbar (7-slot skill bar w/ baked icons, keys 1-7, slots 6-7 padlocked until bought) · boss_bar (kit-colored raid frame w/ 66%/33% phase ticks) · diplomacy_panel (faction relations, key P) · shop_panel (merchant shop, key E near a stall) · waypoint_panel (travel, key T near a waypoint) · cast_bar (teleport channel) · net_debug (F3 overlay) · main_menu · character_creator · lobby_browser
tools/      latency_sim · art_baker/gen_art · art_preview (--preview screenshot scene) · test_worldgen (procgen determinism test) · test_skills (skill-sim determinism test) · test_boss_sim (server-side raid-loop test)
```

The dedicated server hosts **many lobbies at once**; each `Lobby` runs its own
procedurally-generated world (its own `WorldGeometry`, entity states, input queues,
AI) and its snapshots go only to that lobby's peers. `server_world.gd` is the manager
that ticks them all on the shared `GameClock`. A peer that connects sits "in the
browser" until it creates/joins a lobby and reports `ready_in_lobby`.

### Folder boundaries (enforced by convention)
- `shared/` — deterministic sim. Imported by both client and server. **Never**
  import `client/` or `server/` from here, and never touch nodes/rendering/Input.
- `client/` — rendering, prediction, interpolation, input, UI. Never imported by server.
- `server/` — authority, validation, broadcast, AI. Never imported by client.
- `entities/*.gd` — visual shells. They expose `apply_state(EntityState)` and draw;
  they hold **no** simulation logic. Sim lives in `shared/sim`.

---

## Language / style (GDScript)

- GDScript only. **No C#.** The `[dotnet]` section and `.godot/mono` must never
  return to the project.
- `class_name` for every reusable type. Types `PascalCase`, funcs/vars
  `snake_case`, constants `SCREAMING_SNAKE`. One class per file; file name is the
  snake_case of the class.
- Static typing by default (`var x: int`, `func f(a: Vector2) -> void`). Prefer
  `RefCounted` data classes (`EntityState`, `InputCommand`, `Snapshot`) over
  loose Dictionaries for simulation state.
- Tabs for indentation (Godot default).

---

## Netcode conventions

- **Fixed tick = `NetConfig.TICK_RATE` (30 Hz).** The sim runs in
  `_physics_process` (`physics_ticks_per_second = 30`). Always use `NetConfig.DT`
  for simulation math — **never** the frame `delta`. This keeps client prediction
  and server authority numerically identical.
- **All `@rpc` endpoints live on the `NetManager` autoload.** That is the only
  way they share one NodePath (`/root/NetManager`) on every peer, which lets
  `server_root` and `client_root` have different node trees. Worlds talk to the
  network only through `NetManager`'s signals and send-helpers — do not add
  `@rpc` methods to scene scripts.
- **RPC naming:** `receive_input` (client→server), `receive_snapshot`
  (server→a lobby's peers), `ping`/`pong` (clock sync), `despawn_entity` /
  `assign_local_player` (reliable lifecycle), plus the reliable **lobby handshake**:
  `request_lobby_list`/`receive_lobby_list`, `create_lobby`/`join_lobby` →
  `lobby_join_accepted`/`lobby_join_rejected`, `ready_in_lobby`, `leave_lobby`,
  and the reliable gem-economy pair `shop_purchase` (client→server) /
  `gems_event` (server→one peer: balance + delta + reason code). Same shape for
  the waypoint pair `request_teleport` (client→server) / `teleport_event`
  (server→one peer: event code + remaining-cooldown ticks), and the reliable
  broadcast-to-lobby events `orb_event` (pickup taken/respawned) and
  `shrine_event` (faction capture) — marker/toast sync only, awards always ride
  `gems_event`.
- **Lobby handshake order (avoids a lost `assign_local_player`):** create/join →
  server records membership + sends `lobby_join_accepted(id, seed, size)` → client
  stores it in `Session`, loads `client_root`, whose `_ready` builds the geometry,
  connects its snapshot handlers, **then** sends `ready_in_lobby(appearance)` → server
  sanitizes the `Appearance` code, spawns the player with it and sends `assign_local`.
  Snapshots only go to peers that reached `ready`.
- **Character look** is one u16 `EntityState.appearance` (`shared/net/appearance.gd`:
  class/hair-style/hair-color/skin-tone indices; class is VISUAL ONLY — the sim never
  reads the field). It rides in every snapshot so remote clients can bake the right
  sheet lazily (`client/char_painter.gd` + `char_sprite_frames.gd` cache); the chosen
  look persists in `user://character.cfg` via `Session` and is edited in
  `ui/character_creator.gd` (auto-opens on first launch; "Character" menu button).
- **Transfer modes** are what matter for correctness:
  - inputs & snapshots → `unreliable_ordered` (latest supersedes older; loss is
    tolerated, mitigated by `INPUT_REDUNDANCY` for inputs);
  - clock sync → `unreliable` (so RTT isn't inflated by retransmit queueing);
  - lifecycle/handshake → `reliable`.
  All traffic currently shares the default transfer **channel 0** — splitting
  onto separate ENet channels (`NetConfig.CH_*`) is a future refinement, left off
  to avoid channel-count pitfalls.
- Always attribute senders with `multiplayer.get_remote_sender_id()`, and
  **validate/clamp every incoming value** (see `Lobby.push_input`, which clamps move
  length and masks button bits; the manager also clamps lobby size and sanitizes names).
- Entity existence is inferred **lazily from snapshots** (each `EntityState`
  carries its `kind`); only the local-player assignment and despawns travel
  reliably. Per-player input acks ride inside `EntityState.last_input_seq`.
  Projectile nodes are additionally culled client-side when absent from a
  snapshot (closes the reliable-despawn vs in-flight-snapshot ordering race).
- **Skills** are one shared class-blind kit (`AbilityDefs`: melee/bolt/dash/heal/slam
  base + merchant-unlocked NOVA/VOLLEY, ids 10-11 AFTER the boss pool — never renumber
  wire ids), one cast at a time through the `Ability` phase machine; per-slot cooldowns
  live in `EntityState.ability_cds` (u8 each on the wire → cooldowns must stay ≤ 255
  ticks; `ABILITY_COUNT` is 12). Slot↔id contiguity is DEAD: UI maps slots through
  `AbilityDefs.PLAYER_ABILITIES` ([0,1,2,3,4,10,11]); the hotbar sizes off
  `PLAYER_ABILITY_COUNT` (7), not `ABILITY_COUNT`. New button bits must be added BOTH
  to `NetConfig.BTN_*` and the `Lobby.push_input` mask or the server silently strips
  them — all 8 wire bits of the u8 buttons field are now taken (player bits 0-7).
  **Bolt/volley projectiles are spawned/reaped only by the server**
  (`Lobby._spawn_bolts`/`_reap_transients` — ids are server-allocated, the predicting
  client never spawns entities); their flight is shared deterministic code in
  `WorldSim`. A projectile reuses `ability_timer` as TTL, `owner_id` to skip its
  caster, and carries its caster's `upgrades` so flight damage scales identically on
  both ends. The caster sees their own bolt after ~RTT + interp delay — expected.
- **Gems & merchants** (skills-customization economy): killing a boss pays
  `UpgradeDefs.boss_award_for(boss.upgrades)` (tiered: `GEM_AWARD_BOSS_BY_TIER`, the
  center apex pays most) to EVERY player in the last-hitter's faction; killing a plain
  world monster pays `monster_award_for` = `(tier+1)` gems to the **last-hitter only**
  (`Lobby._award_monster_kill`, reason `GEMS_AWARD_MONSTER`; **minions pay nothing** —
  boss summon cycles must never be a gem farm). Kill credit is
  `EntityState.last_hit_by`, stamped at every damage site in the shared sim
  (projectiles credit `owner_id`) but **never serialized** — it is a server-only read,
  reset on revive/respawn and raid reset. Gems are SERVER-ONLY per-peer state
  (`ServerPlayer.gems`, per-lobby, reset on leave — intended); the client learns its
  balance exclusively through the reliable `gems_event` RPC.
  Bought upgrades land in `EntityState.upgrades` — a **sim-read u16**
  (`UpgradeDefs` packing: five 2-bit skill levels, 2 unlock bits, 3 passive bits) that
  rides every snapshot and reconciles via `copy_from` like any sim state; it scales
  damage/heal (`+15%/level`), dash cooldown, move speed (SWIFT), max hp (VIGOR — use
  `EntityDefs.max_hp_of(state)`, never `max_hp_for` when a state is in hand) and
  cooldowns (FOCUS), all integer math, only ever REDUCING cooldowns (u8-safe).
  **Bits 0-1 double as the NPC danger tier** (`UpgradeDefs.npc_tier`, deliberately
  aliasing the MELEE level pair): monsters/bosses never shop, so the tier scales
  monster melee +15%/tier through the existing `damage_for` with zero sim change,
  and `EntityDefs.max_hp_of` reads it for the tiered monster/boss hp tables.
  NOVA/VOLLEY casts are gated on their unlock bit inside `WorldSim._ability_for_buttons`
  — the same fall-through on both ends, so locked presses predict correctly. Merchants
  are NOT entities: one per CORNER island (pinned 3 tiles east of its first village)
  plus `mid_merchants` neutral shops on the fill islands nearest the center — all
  deterministic points in `WorldGeometry.merchants` derived with **zero extra rng
  draws** (the stream shape is load-bearing — never interleave a draw there). The
  client draws stalls (`map_markers`) and opens `shop_panel` on E
  within `MERCHANT_RANGE` of its predicted pos; `Lobby.apply_purchase` revalidates
  EVERYTHING server-side (membership, item id, alive, authoritative-pos range,
  availability, funds) and answers success AND every rejection with a `gems_event`.
  All new NetManager sends inside `lobby.gd` must stay gated on `active.has(peer_id)`
  or the `--script` tests break (they clear `active`; NetManager is unreachable there).
- **Waypoint travel** (`shared/sim/teleport_defs.gd`): T near ANY village/merchant
  (within `WAYPOINT_RANGE`) opens `waypoint_panel`; destinations are **own-faction
  villages + neutral mid merchants only** (`TeleportDefs.can_teleport_to`, shared so
  the panel greys out exactly what the server rejects; enemy corners are unreachable
  by design and `WorldGeometry.merchant_faction(i)` encodes the corner-first append
  law: merchants 0-3 = factions 1-4, 4+ = neutral). The teleport is **NOT a sim
  ability**: the 8 s cast (240 ticks) and 4 min cooldown (7200 ticks) both overflow
  the u8 `ability_timer`/`ability_cds` wire fields, so **long timers live
  server-side** — the channel in `Lobby._teleports` (ticked by `_tick_teleports`
  right after `WorldSim.step`) and the cooldown as `ServerPlayer.teleport_ready_tick`
  (full int, zero snapshot cost, deliberately NOT reset by death). The channel
  **cancels on move/damage/death instead of rooting**: a channeling player stands
  still voluntarily, so prediction stays exact and the completion `s.pos = dest`
  snap is absorbed by the normal hard reconcile (no rubber-band — there is no
  positional smoothing layer). `Lobby.apply_teleport` revalidates EVERYTHING
  (membership, alive, not-busy, cooldown, authoritative-pos near a waypoint,
  allowed destination) and answers success AND every rejection with a
  `teleport_event` whose `data` carries the remaining cooldown.
- **World pickups & shrines** (the exploration/co-op economy): resource orbs
  (`geometry.resources` + `resource_tiers`) and secret caches (`geometry.caches`,
  the **middle segment of each shortcut bridge**, derived with ZERO rng draws) are
  **walk-over pickups** detected server-side from authoritative positions each tick
  (`Lobby._tick_pickups`, `ORB_PICKUP_RANGE`) — no input bit needed (the u8 buttons
  field is full). Awards are tier-scaled (`GEM_AWARD_ORB/CACHE_BY_TIER` — deeper is
  richer), taken state is SERVER-ONLY dicts with full-int respawn ticks, mirrored to
  clients via `orb_event` (+ `send_pickup_state` late-joiner replay); `map_markers`
  hides taken markers, tints orbs by tier, and draws caches as a faint glint only
  (no map marker — discovery IS the mechanic). **Shrines** are a pure function of
  geometry (field islands, index ≥ 5, non-boss, tier ≥ 1, at the island rect
  center — Lobby and `map_markers` derive the identical set): ≥ `SHRINE_MIN_PLAYERS`
  (2) living SAME-faction players inside `SHRINE_RADIUS` channel for
  `SHRINE_CHANNEL_TICKS` (20 s, deliberately NOT cancelled by damage — defending is
  the activity) → tier award to EVERY player of that faction + `shrine_event` toast,
  then a 10 min lockout. Contested/vacant shrines reset progress.
- **Raid bosses** (`KIND_BOSS`) live on **boss islands**, chosen in worldgen
  CENTER-OUT: the center island is always the apex arena, the rest are the fill
  islands nearest the center (sorted `[ring, index]`, zero rng draws; corners are
  NEVER bosses; NO villages and NO regular monster spawns on boss islands;
  SMALL/MEDIUM/LARGE get 2/3/5 bosses, LARGE's player cap is 20 = the raid size).
  Boss hp is TIERED off the island's danger tier riding `upgrades` bits 0-1
  (`EntityDefs.BOSS_HP_BY_TIER` = 6k/12k/24k/45k; index 3 == `NetConfig.BOSS_MAX_HP`
  — the center apex is the full 45k raid boss on EVERY preset, an intentional
  landmark that small lobbies aren't meant to kill; outer bosses fund the economy).
  Always compare/refill boss hp via `EntityDefs.max_hp_of(state)` (phases, raid
  reset, respawn, boss bar) — never the flat constant. The 3 kits (Magma Titan /
  Frost Wyrm / Swamp Horror, 2 biomes each via
  `BossDefs.kit_for_biome`) SHARE one boss ability pool (`AbilityDefs` ids 5–9:
  smash/barrage/summon/hazard/charge) because every ability id costs one cooldown
  byte per entity per snapshot. Kits differ only in `server/boss_ai.gd` pattern
  tables (per-phase move cycles keyed on hp fraction 66%/33%) + client cosmetics;
  **kit rides in `EntityState.appearance`** (visual-only) for bosses and hazards.
  Boss abilities trigger via **AI-only button bits 8–12** — never add them to
  `push_input`'s mask (that mask is the security boundary; AI inputs bypass it and
  never serialize). Summons (minions = `KIND_MONSTER` with `owner_id` = boss id,
  capped live, corpse-reaped, NEVER respawned, inherit the boss's tier bits),
  barrage rings and `KIND_HAZARD`
  ground zones are **server-spawned in Lobby on the first-ACTIVE-tick edge** (the
  `_spawn_bolts` pattern); hazard TTL + periodic players-only damage tick in the
  shared `WorldSim` (pass 2b — the one consumer of the step's `tick` param; hazard
  TTLs must fit the u8 `ability_timer`). Boss respawn = 9000 ticks at home; a hurt
  boss standing at home with no player in aggro range raid-resets to full hp.
  Aggro/leash radii (`BossDefs` 340/460, `AIController` 260/420) are tuned to the
  small islands: the >= 768 px sky gap means aggro can never span between islands.
  World monsters carry their island's tier (count `mon + tier` per field island),
  leash back to their `_monster_home` spawn point and respawn AT it (never another
  island's — that would carry the tier out of its ring).
  Per-kind radius / max hp / sim-role checks go through `shared/sim/entity_defs.gd`
  — never hardcode `ENTITY_RADIUS` or a player-vs-monster hp ternary again.
- **Factions** (`shared/sim/faction_defs.gd`): 4 canonical factions; a lobby enables
  2-4 of them (`faction_count`, the `size` pattern end-to-end: browser OptionButton →
  `create_lobby` → server clamp → `Lobby` field + `info()` → `lobby_join_accepted` →
  `Session`). The pick is made in the character creator (persisted in
  `user://character.cfg`), travels with `ready_in_lobby(appearance, faction)`, is
  validated by `Lobby.assign_faction` (invalid → least-populated, lowest-id tie-break)
  and stamped on `EntityState.faction` — a **dedicated sim-read u8** on the wire;
  NEVER pack it into `appearance` (that field is visual-only and bosses/hazards
  overload it with kit ids). **Each faction starts in its own map corner**: islands
  0-3 are the corner cells (faction = index+1, fixed NW/NE/SW/SE), their villages are
  tagged in `WorldGeometry.village_factions`, and `Lobby._next_player_spawn(faction)`
  round-robins ONLY that faction's corner villages (spawn AND respawn). All 4 corners
  generate regardless of `faction_count` — unused ones are neutral ghost towns, which
  keeps `generate(seed, size)` independent of the faction count. Faction 0 =
  monsters/bosses/their transients = hostile
  to everyone, so PvE and AI targeting ignore factions by construction. The per-lobby
  relation table (6 pairs × 2 bits, u16) rides **every snapshot header** (latest-wins,
  threaded into `WorldSim.step` like `geometry`); PvP damage needs `REL_RIVAL`
  (`FactionDefs.are_hostile` — neutral/allied/same-faction players pass THROUGH
  projectiles, no absorb), and HEAL splashes to nearby same-faction/allied players
  (`are_allied`). Diplomacy is server-validated in `Lobby.apply_diplomacy`:
  rivalry/breaking are unilateral, alliances need MUTUAL proposals ("accept" =
  proposing back — race-free); the reliable `diplomacy_event` RPC is UI-only
  (toasts + the P-key `diplomacy_panel`) and carries relations+tick to merge
  latest-wins against the unreliable snapshot stream. Faction names/colors are
  client cosmetics in `client/faction_palette.gd`.
- Do **not** use `MultiplayerSynchronizer` / `MultiplayerSpawner` for predicted
  entities (players, monsters, projectiles) — we need manual control. They may be
  used later for purely cosmetic/ambient objects only.

### Determinism checklist (review on every `shared/` change)
- No values derived from wall-clock time; ability/cooldown timings in **ticks**.
- No engine physics that can diverge across runs — collision uses explicit math
  in `WorldGeometry`/`Movement`, **not** `move_and_slide`/physics queries.
- Networked inputs are **quantized** (`Serialization.requantize`) so the
  predicting client and the server use byte-identical values.
- `WorldSim.step` iterates entities in **sorted id order** for stable results.
- `WorldGeometry` is now per-lobby data (islands + bridges as a walkable rect union),
  built by `WorldGenerator.generate(seed, size)` from a **seeded** `RandomNumberGenerator`
  in **integer tile units** (×`TILE_SIZE` only at the end). The same seed → byte-identical
  geometry on both ends; the geometry is threaded into `WorldSim.step(states, inputs,
  geometry, tick)`. Only the lobby **seed** travels over the wire — never the rects. The
  collision union is gap-free only because the generator overlaps every connected seam by
  `> 2 * ENTITY_RADIUS`; see `tools/test_worldgen.gd` for the determinism/connectivity test.
  The layout is an ODD square grid of SMALL islands (roles by index: 0-3 corners /
  4 center / 5+ shuffled fill; role-dependent size ranges; danger tier = pure integer
  function of the Chebyshev ring). Keep the RNG **draw budgets fixed** per phase:
  role/boss/merchant selection uses ZERO draws (integer sorts, index tie-breaks), every
  island consumes the same `total_k` point draws with role-dependent keep/discard, and
  every bridge edge (Prim tree first, then the sorted extra shortcuts) draws exactly 2
  values. The tier/faction metadata arrays fold into `debug_hash` — a divergence is loud.

### Known GDScript 4.7 gotcha (do not reintroduce)
Constructing a **native** engine class via `.new()` into a `:=` type-inferred
local **for the first time inside a multiplayer-RPC-invoked frame** trips a
type-resolution bug ("Nonexistent function 'new' in base 'StreamPeerBuffer'").
That is why serialization uses `PackedByteArray` `encode_*`/`decode_*` (a
built-in Variant type) instead of `StreamPeerBuffer`, and why receive-path
decoding happens **outside** the latency-sim lambda. Keep it that way.

The procgen `RandomNumberGenerator` is also a native class, so the same rule applies:
it is **prewarmed** in a normal frame (`Session.warm()` on the client, `server_world._ready`
on the server) and geometry is built **outside** RPC handlers — the client builds in
`client_root._ready`; the server defers lobby construction to the next `_physics_process`
(`_drain_pending_creates`). Always type it explicitly (`var rng: RandomNumberGenerator = …`),
never `:=`.

---

## Where each netcode piece lives
- Deterministic step: `shared/sim/world_sim.gd` (`WorldSim.step`).
- Procedural world: `shared/sim/world_generator.gd` → `shared/sim/world_geometry.gd`.
- Lobby manager / per-lobby tick / per-lobby broadcast: `server/server_world.gd` + `server/lobby.gd`.
- Lobby handshake RPCs + send-helpers: `autoload/net_manager.gd`; client lobby state: `autoload/session.gd`.
- Menu / lobby browser UI: `ui/main_menu.gd`, `ui/lobby_browser.gd` (+ scenes in `scenes/`).
- Prediction + reconciliation: `client/client_world.gd` (+ `prediction_buffer.gd`).
- Interpolation: `client/interpolation_buffer.gd`, sampled at `GameClock.get_render_tick()`.
- Clock sync: `autoload/game_clock.gd` + `ping`/`pong` in `net_manager.gd` (one global tick across all lobbies).

---

## Running & testing

Requires a Godot 4.7 binary (this machine: `/snap/bin/godot-4`).

```bash
# authoritative dedicated server (headless) — hosts all lobbies
godot-4 --headless --path . -- --server --port 24565

# client(s) — opens the main menu → Play → lobby browser → create/join → game
godot-4 --path . -- --client --connect 127.0.0.1 --port 24565

# client with simulated network conditions (for verifying the netcode)
godot-4 --path . -- --client --connect 127.0.0.1 --port 24565 --lag 150 --jitter 40 --loss 0.05

# HEADLESS lobby fast-paths (drive the handshake with no UI — for testing/CI):
godot-4 --headless --path . -- --client --connect 127.0.0.1 --port 24565 --auto-create medium --name foo
godot-4 --headless --path . -- --client --connect 127.0.0.1 --port 24565 --auto-join 1
# --browser jumps a windowed client straight to the lobby browser (skips the menu).
# --class warrior|mage|archer overrides the saved character's class (for testing the
# appearance sync; the full look otherwise loads from user://character.cfg).
# --cast melee|bolt|dash|heal|slam|nova|volley holds that skill button forever and
# prints a per-second "[Bot] hp=.. mon_hp=.. boss_hp=.. entities=.. pos=.." line
# (headless skill checks; boss_hp/mon_hp read the NEAREST boss/monster and vary by
# danger tier — e.g. mon_hp=192 is a tier-1 monster, boss_hp=45000 only at the map
# center — which proves the tier replication path; nova/volley cast NOTHING until
# bought — that IS the sim gate).
# --grant-gems N (SERVER flag) seeds every spawned player with N gems and sends a
# gems_event — the client prints "[Gems] balance=.. delta=.. reason=.." (headless
# proof of the reliable gems RPC; also the fast manual path to test the merchant).
# --faction 1..4 overrides the saved faction pick; --factions 2..4 sets the faction
# count of an --auto-create'd lobby (an out-of-range pick, e.g. --faction 4 into a
# 2-faction lobby, exercises the server's least-populated auto-assign — check the
# server's "faction=N" spawn log line).
# --shot SECONDS (CLIENT flag, windowed only): N seconds after entering the game,
# save a 4-frame burst of viewport captures to res://shot*.png and quit — THE
# visual-verification loop (gitignored; snap godot can only write under $HOME).
# --tod 0..1 (CLIENT flag): force the DISPLAYED time of day (sky + world tint +
# glow layer; 0 dawn / .25 noon / .5 dusk / .75 midnight) — cosmetic only, for
# eyeballing the day/night pass without waiting out the 12-minute cycle.

# regenerate placeholder art (e.g. after changing biomes); determinism tests
# (procgen incl. corner faction islands, danger-tier law, center-out bosses,
# corner+mid merchants, tiered monster counts, orb tiers, shortcut-bridge
# caches, bridge shapes + the skill sim: player kit incl. upgrades/nova/volley,
# boss pool, hazards, serialization round-trip) and the server-side raid loop
# (real Lobby, all 3 kits on the center apex boss: phase patterns,
# summon/hazard spawns, death cleanup, long respawn, raid reset, tiered gem
# awards, faction corner spawns, monster home respawns, monster kill gems,
# apply_purchase, walk-over orb/cache pickups + respawn cycle, the
# apply_teleport validation matrix + cancel-on-move/damage + completion +
# cooldown gate, and shrine capture incl. lockout):
godot-4 --headless --path . --script res://tools/gen_art.gd
godot-4 --headless --path . --script res://tools/test_worldgen.gd
godot-4 --headless --path . --script res://tools/test_skills.gd
godot-4 --headless --path . --script res://tools/test_boss_sim.gd
```

`--script` tool gotcha: the GDScript analyzer resolves autoload CONSTANTS
(`NetConfig.X`) but NOT autoload instance calls (`NetManager.foo()`) — any script
in a tool's compile-time dependency graph must avoid them. That is why
`test_boss_sim.gd` `load()`s `server/lobby.gd` at runtime instead of naming the
`Lobby` class.
With no role flag, a headless display defaults to server, otherwise client. A windowed
client shows the menu; `--auto-create`/`--auto-join` skip it. The connect IP/port double
as the address the menu's Play button uses. Everything after the bare `--` is read via
`OS.get_cmdline_user_args()`.

**Verify (toggle the F3 net-debug overlay):**
- Prediction: the local player responds to input with no perceptible delay even at 150 ms lag.
- Reconciliation: "recon error" stays ~0 px under steady input; it spikes briefly
  then converges on a server correction (e.g. a wall) — no rubber-banding.
- Interpolation: remote entities glide smoothly (no step-teleporting) and trail
  local by ~`INTERP_DELAY_TICKS`.
- Authority: HP is identical across clients; attacking on cooldown deals no extra
  damage (server rejects, client rolls back).

**Headless smoke test** (no display needed): run a server + a client with
`--auto-create medium`. NOTE: an idle client is SAFE now — players spawn on their
faction's monster-free corner island and monsters have an aggro radius (260 px) +
leash, so "idle client loses hp" no longer holds. Instead verify the pipeline via
the `[Bot]` line (`--cast bolt`): the entity count oscillating proves projectile
replication + despawn, `mon_hp`/`boss_hp` prove tier replication (192 = a tier-1
monster's max; 24000 = an inner-ring boss; 45000 only at the center apex), and the
server's "faction=N" spawn log + distinct client positions prove the corner spawns.
Two clients with `--auto-create` get
separate lobbies/maps and never see each other (isolation); `--auto-join <id>` puts a
second client into the first's lobby (same `geometry hash`, both visible).
Per-skill smoke via `--cast`: `bolt` makes the `[Bot]` entity count oscillate
(projectile replication + despawn), `dash` shows ~98 px position bursts until a wall,
`slam`/`heal` need a monster in range — walk the bot off the corner island first (or
check `mon_hp` after the wander), since corner islands hold no monsters.
Teleport smoke via `--auto-tp` (CLIENT flag): the bot requests waypoint travel
every ~2 s and prints `[TP] event=E data=D pos=..` per teleport_event — expect
`event=0` (started, pos = its corner village), ~8 s later `event=1 data=7200`
(completed; the NEXT line's pos is the mid merchant across the map — the snap),
then `event=5` retries whose `data` (remaining cooldown) shrinks by ~60/retry.
An `event=9` (dead) after landing is EXPECTED: mid merchants sit on monster
islands — that is the risk/reward trade. Death does NOT reset the cooldown.

---

## Art pipeline (Golden-Sun style) — ALL art is code-baked, deterministic, in-repo
- Pixel art: import with **Nearest** filter
  (`rendering/textures/canvas_textures/default_texture_filter=0`), no mipmaps,
  integer scaling. The in-game camera runs at **zoom 2x** (client_root.tscn).
- **Color ramps**: every baked palette derives from a base color via
  `client/palette_util.gd` (5-tone hue-shifted ramps: shadows cool, highlights
  warm). PaletteUtil sits in the `--script` tools compile graph — preload-only,
  no autoload refs (same rule as `char_painter.gd`).
- **Character sheets**: 288x96, frame **24x32**, rows DOWN/UP/SIDE (left = flip_h),
  cols idle(0-1) walk(2-7, 6-frame gait) attack(8-11). The contract lives ONCE in
  `client/char_painter.gd` (FRAME_W/H, COLS, *_COLS tables, *_FPS) — ArtBaker,
  CharAnim and CharSpriteFrames alias it; change it there and re-bake. Players are
  runtime-baked per Appearance; `Appearance.DEFAULT` must reproduce the committed
  `player.png` byte-identically. Monsters come as 3 species sheets
  (slime/beetle/wisp) picked client-side from the island biome
  (`client/monster_skins.gd` — cosmetic only). Bosses are bespoke 640x128 sheets
  (frame 64x64, 10 cols x 2 rows: FRONT serves down+up, SIDE flips), one per kit,
  selected by the appearance/kit field; sprite offset -20, no node scale.
- **FX**: every combat effect is a baked strip (`fx_*.png`) played by the one
  generic `entities/effects/sheet_effect.tscn`; `client/effect_spawner.gd` holds
  the data-driven registry (frames/tint/scale/additive/rotate per EffectIds id)
  and prebuilds ALL SpriteFrames + the shared additive material in `_ready` (the
  4.7 native-.new()-in-RPC-frame rule). One neutral white `fx_ring.png` serves
  slam/smash/nova via tint + node scale = sim radius. Projectiles/hazards are
  animated shells that only ASSIGN the caches (`EffectSpawner.bolt_frames` /
  `hazard_frames` / `glow_tex`). Entities hit-flash on hp decrease (modulate).
- The map is drawn as TILING textured rects (islands are millions of cells — far too
  many for a `TileMapLayer`), not per-cell tiles, and must keep matching `WorldGeometry`
  (the sim collides against the walkable union, not the picture). `floor_renderer.gd`
  composes a 64x64 patchwork from 4 floor variants (fixed FLOOR_MIX — no visible
  checker), tiles it per island, adds an inner AO band, a grass-overhang fringe
  strip along bottom edges (atlas col 5) and the floating-island underside
  (layered drop shadow + rocky rim + sun-lit band + reverse-pyramid stone mass,
  atlas **cliff** col 4); bridges get a wood-plank deck with rope rails.
  `water_renderer.gd` (+ `water_layer.gd`, `water.gdshader`) adds animated ponds
  (soft noise-faded banks) + waterfalls; `foliage.gd` scatters swaying grass
  (batch), rocks + per-biome ground decals (batch), and TREES as individual
  Sprite2Ds re-parented into client_root's y-sorted `Playfield` (with `Entities`)
  so actors walk in front of/behind trunks — same seeded RNG streams, NEVER
  reorder the `_scatter` calls. Water/foliage/glow placement is client-side,
  derived from the lobby seed, and never touches the sim. Islands float in the
  procedural `sky.gdshader` (no water backdrop). All of these animate via a phase
  uniform fed from the synced `GameClock` in `client_world`
  (`_update_sky`/`_update_env`) — never the shader `TIME`.
- **Day/night**: one `CanvasModulate` (`WorldTint` in client_root) driven by
  `client_world._update_sky` on the synced clock — 4-key cyclic blend, night
  blue-shifts and never drops below ~0.5 luminance (combat readability).
  Sky/HUD are separate CanvasLayers and stay untinted. `world/glow_layer.gd`
  (additive quads at orbs/runes/shrines/banners/lava + night-only hut windows)
  brightens as the tint darkens. No Light2D — glows + modulate only.
- Terrain atlas (`assets/tiles/terrain.png`, baked by `tools/art_baker.gd`): 6 cols
  (floor/floor_alt/floor_var2/floor_var3/**cliff**/**edge-fringe**) ×
  `BiomeRegistry.BIOME_COUNT` rows (currently 6: forest/desert/snow/swamp/volcano/
  savanna; palettes = PaletteUtil ramps + per-biome overrides). Add a biome = new
  base color + bump `BIOME_COUNT`, then re-run `gen_art.gd`. The baker also emits
  `bridge.png`, `foliage.png` (12 cells in 2 rows: tree x3/grass/rock x2 +
  flower x2/pebbles/crack/stump/bush decals), `icons_skills.png` (24x24 cells BY
  ABILITY ID for the hotbar) and the **pixel font**.
- **UI**: `assets/fonts/pixel.fnt` + `pixel.png` are BAKED (classic 5x7 glyphs in
  6x9 cells, ASCII 32-126; BMFont channel spec must be `alphaChnl=0 redChnl=4
  greenChnl=4 blueChnl=4` or Godot's importer rejects it; if the importer ever
  wedges with `valid=false`, delete `pixel.fnt.import` and re-import).
  `client/ui_theme.gd` builds the runtime Theme (pixel font at size 18 = crisp 2x,
  `FIXED_SIZE_SCALE_INTEGER_ONLY`, UiPalette styleboxes) — applied in
  main_menu/lobby_browser/character_creator `_ready` and `UiTheme.apply(hud)`;
  `gui/theme/custom_font` covers stragglers. Use font sizes 9/18 only.
- Assets in `assets/sprites|tiles|fonts`; commit `.import` files. Preview any art
  change with `--preview` (tools/art_preview.gd: world + characters + species +
  bosses + FX sheets) or in-game with `--shot`/`--tod`.
