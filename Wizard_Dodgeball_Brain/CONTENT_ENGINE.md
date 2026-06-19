# WIZARD DODGEBALL — CONTENT ENGINE (Progression · Decks · Economy)

> Master Context File. The authoritative spec for the player-facing content/progression
> systems built ON TOP of the (complete) core game. Companion to `Cards_Spells.txt`
> (card DATA spec), `CARD_FRAMEWORK.md` (card authoring + runtime), and the economy
> section of `Wizard_Dodgeball_Manifesto.txt`.
>
> **This file SUPERSEDES the older "mana / draft-choice / off-color token" deck description
> in those companions.** Where they disagree, this file wins for the deck + economy model.
>
> STATUS: ROADMAP — approved 2026-06-19 by the Creative Director. Phases P0–P7 in §9. No
> code shipped yet; this is the design contract the build follows.

---

## 0. WHY THIS EXISTS
The core game is DONE — offline + LAN/online rollback netplay, Bo3 rounds + KO cinematics,
the cosmetics-skin pass (palette-swap shader, 5 skins, equip→match), the AI difficulty
selector. The **Content Engine** adds the retention loop the Manifesto always called for:

> **earn → open → build → play.**

- **LEVELS:** every match grants XP; each new level grants a card pack; each level costs more XP.
- **DECKS:** players build a 15-card deck (5 attack / 5 counter / 5 defense) from owned cards;
  the in-round hand of 3 cycles through it.
- **ECONOMY:** packs (spells + skins + coins), a Coins soft-currency, Gems premium currency,
  and a Forge that turns duplicates UP a rarity tier (so no pull is ever worthless).

---

## 1. THE TWO-LAYER RULE (the determinism backbone — read this first)
Everything here splits into two layers, and the split is WHAT KEEPS THE 20/20 DETERMINISM
SWEEP BIT-IDENTICAL and online play desync-free. Violating it is how this whole feature
breaks the game.

| Layer | Owns | Determinism |
|---|---|---|
| **META** — `PlayerProfile` autoload → `user://profile.cfg` | XP, level, coins, gems, owned-item counts, the saved 15-card deck, pack rolls, the forge | **NONE.** Single-player, pre/post-match, per-peer. Normal `RandomNumberGenerator` is fine. **NEVER read inside a sim tick.** |
| **SIM** — in-match, `CardCasterComponent` | which card is "current" in each of the 3 slots, the per-slot cycle INDEX, cooldowns | **MUST be bit-identical across peers.** Card `.tres` are shared immutable data; the cycle index is saved sim-state; the deck CONTENT is fixed at match start (exchanged at handshake online). |

**THE RULE:** the meta layer is touched ONLY outside a sim tick — menus, match-start setup,
match-end reward. The sim NEVER reads `PlayerProfile` mid-tick. The deck is SNAPSHOTTED into
the caster once at match start; after that only an integer cycle index changes. This is the
same discipline that made the skin system rollback-safe by construction.

---

## 2. PERSISTENCE — `PlayerProfile` (`user://profile.cfg`)
A NEW autoload, sibling to `GameSettings`, using the identical proven pattern: load in
`_ready()`, each `set_*()` writes the `ConfigFile` + emits a `*_changed` signal, consumers
read once + connect to the signal. Sections:

- `[progression]` — `xp:int`, `level:int`
- `[wallet]` — `coins:int`, `gems:int`
- `[inventory]` — `spells` (id → count), `skins` (id → count)
- `[deck]` — `attack` (5 ids), `counter` (5 ids), `defense` (5 ids)

SEPARATE file from `settings.cfg` — keeps economy state apart from presentation prefs.

**TEST HERMETICITY — the hard-won lesson (the `ai_difficulty` incident, see memory
`ai-difficulty-normal-preset-pass`):** the determinism sweep reads the REAL `user://` dir even
headless. A persisted non-default deck would change WHICH CARDS enter the sim and break
bit-identity. So:
- `PlayerProfile` must default-construct safely with NO file present (a legal default deck).
- From P3 on, **every suite that builds a match MUST pin a known default deck before
  `add_child`** (pre-`_ready`), exactly like the two suites that now pin `ai_difficulty = 1`.

---

## 3. LEVELS & XP
- Hook: `MatchController.match_ended(player_won)` — a META signal that fires once per match
  end, per-peer (`core/match_controller.gd:865`). Award XP (win > loss) + Coins, then resolve
  level-ups.
- Curve: `xp_to_next(level) = base · level^1.5` — escalating ("each level takes more XP").
- PROPOSED defaults (ALL TUNABLE): `base = 200`, win = 100 XP, loss = 40 XP, + Coins per match.
- Each level-up grants **1 pack**, queued in the profile, opened in the Deck/pack flow.
- **Online-safe for free:** XP is meta, awarded per-peer from that peer's OWN win/loss — no
  sync, no determinism concern. Only the deck CONTENT needs cross-peer agreement (§8).

---

## 4. THE DECK (15 cards) + IN-ROUND CYCLING ("draw")
**CD DESIGN, 2026-06-19 — this SUPERSEDES the Manifesto's mana/draft model (playtesting
killed it):**

- **Deck = 15 cards:** 5 ATTACK + 5 COUNTER + 5 DEFENSE.
- **Hand = 3** — one of each type visible at a time. This is EXACTLY today's 3 slots
  (keys 8 / 9 / 0), unchanged.
- **NO mana. NO draw-choice.** The existing card-pop animation IS the "draw": when a slot's
  card is used and its cooldown elapses, the card that pops in is the **NEXT card of that type
  in the deck.** Each of the 3 slots cycles through its own 5-card type-pool.
- **CYCLE ORDER = SEQUENTIAL** (index 0→1→2→3→4→0). Deterministic, ZERO RNG to sync — the
  clean rollback fit. (A random next-card is possible but would need a seed synced at the
  handshake; NOT chosen.) "A different card of the same type" is satisfied whenever the deck
  has variety; a deck of 5 identical copies legitimately pops the same card.
- **DECK-BUILD COPY LIMITS** (enforced in the BUILDER UI, never at runtime):
  - max **5×** the same COMMON,
  - max **2×** the same UNCOMMON,  *(CD revised 2026-06-19 from 3 → 2 during the Decks overhaul)*
  - max **1×** the same RARE.
  - SINGLE SOURCE OF TRUTH: `PlayerProfile.COPY_LIMIT = {0:5, 1:2, 2:1}` (rarity→max). The builder's
    quantity-prompt cap = `min(copy_limit − in_deck, owned − in_deck, 5 − type_count)`.
- Every player AND the AI always holds a LEGAL 5/5/5 deck — a **DEFAULT STARTER DECK** ships so
  new accounts and the offline opponent are never illegal/empty.

**RUNTIME CHANGE (P3):** `CardCasterComponent`'s three single `card_slot_*` exports become
three 5-entry type-cycles + a per-slot **current-index** (a NEW saved sim-state int). Match
start snapshots the deck in; only the index advances afterward (on use + cooldown). Fully
rollback-safe — the index is in `_save_state`/`_load_state`, the cards are immutable data.
This also retires the "4 s cooldown is a placeholder until the deck system" note in
`CARD_FRAMEWORK.md` — cooldown now DRIVES the cycle advance.

---

## 5. ECONOMY — packs, currencies, forge
**Currencies** (Manifesto §3 — *"premium currency strictly reserved for cosmetics… No
pay-to-win"*):
- **COINS** (soft) — earned from matches + packs; spent on more packs.
- **GEMS** (premium) — earned sparingly; the only currency that DIRECTLY buys premium geometry
  skins.

**Packs** — a pack is a set of revealed "cards"; **two flavors, each also drops Coins:**
- **SPELL pack** → spell cards + Coins.
- **COSMETIC pack** → skin cards + Coins.
- Contents are RANDOMLY generated, RARITY-WEIGHTED (meta RNG — no determinism constraint).
- **Rare pulls:** recolor skins span COMMON→RARE; the **premium GEOMETRY skins (cyber / neon /
  space) CAN appear in cosmetic packs but as VERY RARE finds** — the rare-of-rares cosmetic.
  They ALSO remain directly buyable with Gems. (Still no pay-to-win: they are cosmetic, and
  now also earnable free.)

**Forge / cash-in** — the "never worthless" sink, applies to BOTH spells and skins:
- **5 COMMONS → 1 random UNCOMMON** (same item class — spell→spell, skin→skin).
- **3 UNCOMMONS → 1 random RARE.**
- Duplicates BEYOND a deck's copy-limit are the natural forge fuel.

**Rarity** lives on both item classes: spells already carry `CardResource.rarity`
(COMMON/UNCOMMON/RARE); **skins need a rarity tier ADDED** (to `SkinCatalog` metadata or
`SkinPalette`).

---

## 6. WHAT THE CURRENT SPELL FRAMEWORK CAN DO BY PARAMETERS ALONE
*(Verified 2026-06-19 against `resources/spell_resource.gd`, `resources/card_resource.gd`,
and the consuming components.)* The framework's ONE RULE holds: **unique-feeling moves come
from PARAMETERS, not bespoke card code** — see `CARD_FRAMEWORK.md`.

### WIRED today → author a card with PURE `.tres`, NO code:
- **Ballistics (every card, from `SpellResource`):** `projectile_scene`, `base_speed`,
  `damage`, `projectile_size`, `bounciness` (wall-ricochet retention → multi-bounce trick
  shots), `cast_time`, `element` (Fire / Spark / Ice impact colour).
- **ATTACK:** `lifetime`, `projectile_count` (1–5, auto-fanned), `spread_x_speed` (spread
  width), `stage_ticks` (countdown length), `homing_strength` (0–1 seek), `barrier_breaker`
  (shatter + split through walls).
- **DEFENSE:** `wall_size`, `wall_lifetime`, `wall_movement_speed` (drifting walls),
  `wall_offset_y`, + full WOA: `woa_range`, `woa_max_reflect`, `woa_max_hold_seconds`,
  `woa_ricochet`.
- **COUNTER:** `slow_duration`, `slow_scale_weak` / `slow_scale_strong` (WOA-scaled slow),
  `speed_modifier`.
- **Per-card presentation:** `screen_shake_intensity`, `cast_vfx_scene`,
  `cast_animation_name`, `ui_sprite`, `world_sprite`.

→ This already covers nearly ALL **commons + uncommons**: fast/slow/heavy/light bolts,
spread-shots, homing arcs, multi-bounce trick shots, barrier-breakers, big / small / drifting
walls, harsher or softer shields, longer / colder freezes — every one of those is DATA.

### DECLARED but NOT wired anywhere in `scripts/` → need NEW RUNTIME CODE:
`is_exploding`, `rebound_window` (Perfect-Parry), `healing_absorb`, `cast_while_charging`,
`movement_dash_distance`, `conditional_draw`, `teleport_distance`, `freeze_duration`,
`phase_immunity`. *(Confirmed unconsumed — they exist only in `card_resource.gd`'s
definition, each commented "effect lands with later cards.")*

→ These are the **EXOTIC mechanics.** As the CD anticipated: **RARES will generally need new
runtime wiring AND likely brand-new parameters** (+ a bespoke `cast_vfx_scene` and
`screen_shake_intensity`) to look and feel distinct from the param-tuned commons/uncommons.
Budget each RARE as a small MECHANIC FEATURE — wire one declared field, or invent a new one —
each determinism-checked individually. A Rare is NOT a pure `.tres`.

---

## 7. UI / NAVIGATION
- **NEW dedicated DECK screen** — themed with `ui/main_theme.tres` + `Y2KButton` per
  `ui_design_system.md`. Browse owned spells by type, build the 5/5/5 deck under the copy
  limits, persist to `PlayerProfile`. Pack-opening + Forge live in this flow (reveal
  animation; cash-in 5→1 / 3→1).
- **HOME SCREEN gets two CLICKABLE 3D objects**, each with an EDGE-GLOW on hover + a SHAKE on
  click (visual feedback the CD asked for):
  - the **WIZARD sprite** → opens **Cosmetics**,
  - a new **DECK model** → opens the **Deck screen**.
  (The home screen already mounts the cosmetics podium wizard rig; add input picking +
  hover-glow + click-shake, then `change_scene_to_file`.)
- **Cosmetics binding:** its currency labels (today static `coins = 1250` / `gems = 8` in
  `scripts/ui/cosmetics.gd`) bind to `PlayerProfile`; `SkinCatalog.DEV_UNLOCK_ALL` flips to
  `false` and `is_owned()` reads the real inventory — the catalog was BUILT for exactly this
  swap ("flip the flag the day real ownership lands, no other code change").

---

## 8. ONLINE (in scope for this build — CD chose "include online now")
- **DECK EXCHANGE:** extend the handshake (the reliable ready-exchange `@rpc` barrier BEFORE
  `SyncManager.start()`, in `core/net/rollback_session.gd` / `core/network_manager.gd`) to
  carry each peer's **15 card-ids + equipped-skin id**. Both peers apply BOTH decks to the
  correct wizard + both skins BEFORE the sim starts. Cards load BY PATH (export-safe, the same
  reliability caveat `SkinCatalog` already works around). Sequential cycle + identical deck
  ORDER ⇒ identical "current" card on both peers every tick.
- **OPPONENT-SKIN SYNC** closes the long-standing cosmetic gap (each peer previously showed
  only its own equipped skin; see the COSMETICS-SKIN PASS "known limitations" in HANDOFF).
- **VERIFY:** a LAN smoke with **DIFFERENT decks per peer** must stay BYTE-IDENTICAL across
  rounds, including card casts + slot cycling (extend `_smoke_fingerprint`).

---

## 9. ROADMAP (each phase independently committable; the sweep stays bit-identical)
> **STATUS — wave 1 SHIPPED (commit `ab25938`, 2026-06-19):** P0 ✅ (`PlayerProfile` + `profile.cfg`);
> P2 🟡 (4 of N cards: 2 attack commons + 2 defense buffs — RARES + the rest pending); P3 🟡 (BASIC
> offline loadout = ONE active card per slot, headless-hermetic; the 15-card cooldown-CYCLING deck is
> still TODO); P4 🟡 (full 5/5/5 deck-BUILDER SHIPPED 2026-06-19 — landing + builder + inspect + qty-prompt,
> see §13; the home-screen clickable 3D model is the last P4 piece TODO).
> P1 (XP/levels), P5 (packs/forge), P6 (online deck exchange), P7 (APK/sync) = TODO. **See §11 for exactly
> what's built, and §12 for the move-authoring recipe.**
- **P0 — Profile spine** *(meta-only)*: `PlayerProfile` autoload + `user://profile.cfg` +
  default starter deck; add skin rarity; flip `DEV_UNLOCK_ALL`; bind cosmetics
  currency/ownership; hermetic test scaffolding.
- **P1 — XP & levels** *(meta-only)*: `match_ended` → XP + Coins → escalating curve →
  queued pack(s); post-match XP-bar / level-up beat.
- **P2 — Card content pool**: author commons + uncommons (pure `.tres` from §6's WIRED
  surface) + **1 RARE per category** (bespoke code + new params + bespoke VFX). The largest
  authoring chunk; PREREQUISITE for a meaningful deck (you can't choose with one card/slot).
- **P3 — Deck data + in-round cycling** *(SIM change — the determinism-critical phase)*: the
  `CardCasterComponent` 5-cycle + sim-state index; match-start deck snapshot (offline: player
  deck vs default AI deck). Full sweep + LAN smoke verified.
- **P4 — Deck builder screen + home-screen interactivity**: the 5/5/5 builder + copy-limits;
  clickable 3D deck model + wizard (edge-glow + click-shake).
- **P5 — Packs + reveal + forge**: two pack types + Coins, seeded rarity-weighted rolls,
  flip-reveal UI; level-up grants; forge 5→1 / 3→1 (spells + skins); Coins sink (buy packs).
- **P6 — Online deck exchange + opponent-skin sync**: handshake carries both decks + skins;
  LAN smoke with DIFFERENT decks stays byte-identical.
- **P7 — Verify + APK + Brain doc sync (Delta)**: full sweep + LAN/online smoke + screenshots
  + re-export `SpellBop.apk`; Delta does the closing-ceremony archival sync.

---

## 10. DETERMINISM CHECKLIST (every phase)
- [ ] Meta state read ONLY outside sim ticks; deck snapshotted at match start, never re-read.
- [ ] Cycle index in `_save_state` / `_load_state`; card `.tres` immutable + shared.
- [ ] Suites that build a match PIN a default deck + profile pre-`_ready` (hermeticity).
- [ ] New `class_name` / scene-spawn names → `--headless --import` once before the suites.
- [ ] Online: decks exchanged BEFORE `SyncManager.start()`; LAN smoke byte-identical with
      asymmetric decks.
- [ ] 20-suite sequential sweep bit-identical after every committed phase.

---

## 11. BUILT SO FAR — wave 1 (commit `ab25938`, 2026-06-19)
**Systems live:**
- `PlayerProfile` autoload (`core/player_profile.gd`) → `user://profile.cfg`: `[progression]`/`[wallet]`
  stubs + `[deck]` = ONE active card id per slot. Defaults reproduce `player.tscn`.
- `CardCatalog` (`scripts/cards/card_catalog.gd`) — export-safe id→path registry of all cards (+ type/rarity).
- BASIC **Decks menu** (`scenes/decks.tscn` + `scripts/ui/decks.gd`) on the home-menu DECKS button —
  pick the active card per slot, persisted.
- `MatchController._apply_loadout()` — OFFLINE loads the equipped cards into the caster at match start.
  **HEADLESS-GATED** (`DisplayServer.get_name() == "headless"` → return) so the determinism suites ignore
  the saved deck; online keeps scene-default cards (deck exchange = P6).
- **Defense BUFF archetype** — a DEFENSE card with `buff_duration > 0` applies a timed SELF-BUFF instead
  of deploying a barrier (`CardCasterComponent._resolve_buff`).

**The card pool (7):**

| id | name | type | faction | what it does |
|---|---|---|---|---|
| `spark_bolt`  | Spark Bolt   | ATTACK        | RED   | shield-shatter + split, 20% homing, 2 DMG *(baseline)* |
| `slow_boulder`| Slow Boulder | ATTACK        | GREEN | slow (440 u/s), 2× size (72u), reflectable, 1 DMG |
| `swift_dart`  | Swift Dart   | ATTACK        | RED   | fast (980 u/s), small (16u), reflectable, 1 DMG |
| `gaeas_wall`  | Gaea's Wall  | DEFENSE       | GREEN | one-way wall + WOA reflect *(baseline)* |
| `hermes_boon` | Hermes' Boon | DEFENSE(buff) | RED   | +50% move speed 4 s, no wall |
| `focus_sigil` | Focus Sigil  | DEFENSE(buff) | BLUE  | −50% fireball charge + cooldown 5 s, no wall |
| `icey_retort` | Icy Retort   | COUNTER       | BLUE  | frost wave, 150u half-width (−25%), 3 s slow *(baseline)* |

**Determinism:** 20/20 sweep bit-identical; headless-hermetic to any saved deck.
**NOT built yet:** the 15-card cooldown-CYCLING deck (only 1 active card/slot now), XP/levels (P1),
packs/forge (P5), online deck exchange (P6), the home-screen clickable 3D + full 5/5/5 builder (P4 full).

## 12. HOW TO ADD A NEW MOVE — the authoring recipe
**First decision: param-only, or needs code?** Check §6. If every effect maps to a WIRED `CardResource`
field → Recipe A. If it needs a new behavior → Recipe B/C.

### Recipe A — a PARAM-ONLY card (most commons/uncommons; NO code)
1. Duplicate the closest baseline `.tres` in `resources/cards/` (attack→`spark_bolt.tscn`, defense→
   `barrier.tscn`, counter→`ice_wave.tscn`).
2. Tune ONLY the WIRED params (§6): speed/damage/`projectile_size`/`bounciness`/`element`/`lifetime`/
   `projectile_count`/`spread_x_speed`/`homing_strength`/`barrier_breaker` (attack); `wall_size`/`wall_lifetime`/
   `wall_movement_speed` + the WOA block (defense); `slow_duration`/`slow_scale_*` (counter). Set
   `faction`/`rarity`/`is_card = true`/`description`.
3. Add a `{id, path, type, rarity}` entry to `CardCatalog.ENTRIES`.
4. `--headless --import`, then the 20-suite sweep (bit-identical). *(Examples: `slow_boulder`, `swift_dart`.)*
Note: the COUNTER wave's collision width is in `ice_wave.tscn` (`extents_x` + `HitDetectionComponent.hit_extent_x`
+ the `BoxMesh`), NOT `projectile_size` (which only drives the spawn-clamp) — change ALL THREE together.

### Recipe B — a NEW BUFF (the Defense buff archetype)
1. **CardResource**: add the buff param (e.g. `move_speed_buff`, `fireball_haste`) in the "Buff" subgroup.
2. **Target component**: add a timed modifier — sim state `_X_ticks` + `_X_scale_fp`, decremented per
   `_network_process` tick, applied in the component's math, **SAVED in `_save_state`/`_load_state`**,
   RESET-not-stack on re-apply, cleared in `reset_cast_state`/`halt`. *(Examples:
   `MovementComponent.apply_timed_boost` → `"bt"/"bs"`; `SpellCasterComponent.apply_timed_haste` →
   `"ht"/"hs"`, which scales the charge STEP + cooldown without touching the threshold math.)*
3. **`CardCasterComponent._resolve_buff`**: convert the float → fixed-point + whole ticks ONCE, call the
   component's apply method (the component is found in `_ready`, like `_movement`/`_spell_caster`).
4. **HUD**: `is_defense_buff()` already makes a buff defense card always-shown (not threat-gated).
5. Author the `.tres` (`card_type = 1`, `buff_duration > 0`, the buff field), add to `CardCatalog`, verify.
   Write a focused probe (model `tests/probe_buff_cards.gd`).

### Recipe C — a NEW MECHANIC (rares / exotic; the hardest)
Wire a declared-but-unwired field (`is_exploding`, `rebound_window`, `healing_absorb`, `teleport_distance`,
`freeze_duration`, `phase_immunity`, `movement_dash_distance`, `conditional_draw`) or invent one: implement
it in the resolve path + the projectile's `_network_spawn`/movement, with ANY new sim state SAVED. Budget
each as a small feature with its own determinism pass + bespoke VFX (`cast_vfx_scene`/`screen_shake_intensity`).
NOT a pure `.tres`.

### The SPAWN PAYLOAD pattern (projectiles / walls)
Build an int/fixed-point + path-string payload → `SyncManager.spawn(name, container, scene, data)` → the
entity's `_network_spawn(data)` rebuilds it (every spawn AND every rollback re-sim). Node refs become
**absolute paths** resolved in `_network_spawn` (`"src"`, `"tgt"`). The caster mutates its OWN sim state
(e.g. consume the stack-winner speed boost) in ITS tick, never in `_network_spawn`.

### THE DETERMINISM COMMANDMENTS (break one → online desyncs / the sweep fails)
1. **All sim state in `_save_state`/`_load_state`, int/fixed-point only.** A one-shot latch (damage applied,
   capture armed, buff active, cycle index) MUST be saved or a rollback past it leaves it stuck.
2. **Float → fixed-point ONCE** at cast/spawn (`SGFixed.from_float`), never in the per-tick hot path.
3. **Timed effects: RESET-not-stack**, decrement per tick, save the timer + scale.
4. **Autoloads via `/root` in early-compiled scripts.** A bare `SyncManager`/etc. fails to COMPILE in any
   script pulled early into the graph (anything reachable from `AIBrainComponent` → `CardCasterComponent`).
   **Adding a typed/`class_name` ref to a component from an early script DRAGS that component into the early
   graph too** — audit it for bare autoloads (this bit us: `card_caster`→`spell_caster`→bare `SyncManager`,
   fixed via `get_node_or_null(^"/root/SyncManager")`). Memory `syncmanager-autoload-compile-order`.
5. **Hermeticity: the headless sweep reads `user://`.** The offline loadout is headless-gated so suites
   ignore the saved deck; AI-sensitive suites pin `GameSettings.ai_difficulty = 1`. Never let a suite depend
   on persisted player state. Memory `ai-difficulty-normal-preset-pass`.
6. **Presentation from a sim signal / `_network_process` hook → `is_in_rollback()`-guard it** (it re-fires
   once per rollback re-sim, spawning duplicate VFX otherwise).

### VERIFY (every move)
- `--headless --import` once (REQUIRED after any new `class_name` / scene-spawn name).
- The **20-suite sweep, STRICTLY SEQUENTIAL** (two headless instances DEADLOCK on the `.godot` cache),
  **bit-identical**. 4.6.3 console binary (memory `godot-version-463`).
- A **focused probe**: build the component standalone, apply the effect, assert (a) functional, (b) survives
  `_save_state`/`_load_state`, (c) save→ticks→load→replay is BIT-IDENTICAL. Model `tests/probe_buff_cards.gd`.
  Standalone components needing an autoload must reach it via `/root`; pass input dicts with **StringName
  keys** (`{&"x": 1}` / `{&"c": 1}` — `InputCommand.get_x/get_cast` read `&"x"`/`&"c"`; a String key silently misses).

### DIAGNOSTIC gotchas (cost real time — see the HANDOFF graveyard)
- A component **never ticking** (0 debug prints) = a **compile cascade** upstream; read STDERR for
  "Compile Error / Failed to compile depended scripts" BEFORE debugging the feature logic.
- **"nothing spawned"** for a defense card can mean a **buff card resolved to the no-barrier path** —
  check the persisted deck (`user://profile.cfg`), not the spawn code.
- Test `printerr` failures print to **STDERR**, not stdout — scan both (or trust the suite's exit code).

## 13. DECKS PAGE OVERHAUL — SHIPPED (2026-06-19)
The thin text-button picker is REPLACED by a full two-state deck-builder (`scripts/ui/decks.gd`, ~700 lines;
`scenes/decks.tscn` is just the root Control + script). Built so moves can be authored + eyeballed fast:

- **STATE 1 — "MY DECKS" landing:** the deck BOXES hero-centred (placeholder `DeckBoxIcon` art) — one active
  deck + two LOCKED "purchasable upgrade" slots. Tap the active box → tweens down into the bottom dock,
  revealing the builder.
- **STATE 2 — BUILDER (40/5/40/15 split):** TOP deck list (5 slots/type, empty slots dashed, the slot-0
  "loaded in match" card gets a green border) · SEP bar (`DECK x/15` + 🔴/🟢/🔵 per-type counts) · filter
  strip (search + type/rarity chips) · inventory grid (rows of 3, scroll) · bottom dock (docked box + swipe
  arrows + Back).
- **CARD VARIANTS:** small tile (70/30 text/art + owned `xN` badge, faction-tinted, rarity stripe, type
  glyph) and a BIG inspect modal (50/50, scales up over a darkened backdrop, tap-out to dismiss; shows the
  full `description` + every mechanic + ADD / REMOVE / LOAD-IN-MATCH).
- **INTERACTIONS:** drag inventory→deck (drop anywhere in the list, +1); double-tap OR the qty badge → a
  quantity prompt whose max is the DYNAMIC cap; deck-tile tap → inspect, double-tap → remove. Rejections
  shake the type counter + buzz (`Input.vibrate_handheld`) + toast the reason. Haptics on pickup/drop/modal.
- **DATA (`PlayerProfile`):** the deck is now up to 5 ids/type (was 1); `owned_count` is dev-granted (6/3/2
  by rarity — exceeds the cap so the dynamic cap is testable) until packs land (`DEV_GRANT_ALL`, mirrors
  `SkinCatalog.DEV_UNLOCK_ALL`). `add_card`/`remove_card`/`make_active`/`max_addable`/`copy_limit` are the
  builder API. Still 100% META — offline still loads only `deck[type][0]`, headless-gated; **20/20 sweep
  bit-identical**, probe `tests/probe_decks.gd` + screenshots `tests/screenshot_decks.gd`.
- **STILL TODO (P4):** the home-screen clickable 3D deck model (edge-glow + click-shake) → this screen, and
  the actual in-round 15-card cooldown CYCLING (P3 sim change — the builder persists the deck; the sim only
  consumes slot 0 today).
- **POLISH PASS (CD batch 2, same day):** editable DECK NAMES (under the box on the landing + in the dock;
  persisted `[deck] name`, `PlayerProfile.set_deck_name`); cards COLOURED BY TYPE (red attack / green defense
  / blue counter, matching `card_hand_hud.TYPE_COLORS`) — faction is now text-only; the BIG view rebuilt to
  read like the IN-MATCH card (gold MTG frame, type-coloured header, the real type art icon, two bordered
  text boxes with `clip_contents` so text never spills) + the full stat line + ADD/REMOVE buttons; the slot-0
  "loaded" card carries a GOLD border (stands out on all three type colours); dragging a card focus-DIMS the
  other-type cards (smooth tween) and dropping onto a FILLED same-type slot REPLACES it (`replace_at`). The
  inventory dock was raised to kill the empty void. Verified: `probe_decks` + 20/20 sweep + 6 screenshots.

**Next:** P2's card-content push (Ricochet Round, Mitosis Bolt, the stack-manipulating counters Mirror Thief
/ Siphon Ward, + the first RARE per category) — now testable card-by-card in the new builder.

## 14. NEXT — CARD CREATION ENGINE (drag-and-drop authoring; CD direction 2026-06-19)
**Before hand-authoring more moves**, the CD wants a drag-and-drop card pipeline that MIRRORS the wizard
SKIN/sprite system: drop a card's art into a folder and the card auto-appears in `CardCatalog` → the Decks
builder → the in-match hand, with NO hand-editing of `.tres` or the catalog. The RUNTIME is already ready —
`CardResource.ui_sprite` / `world_sprite` hooks are wired (just UNSET), and the Decks tiles + big inspect
already read `ui_sprite` (falling back to drawn glyphs / the `TYPE_ART` placeholders). Only the EDITOR tooling
is missing: an `@tool` `card_pipeline` plugin modelled line-for-line on `addons/wizard_pipeline/plugin.gd`
(watch `res://assets_final/cards/<id>/`, regenerate the card `.tres` + `CardCatalog.ENTRIES` ONLY-when-changed
to avoid the save→`filesystem_changed` loop). Art is PRESENTATION ONLY (never sim) so the sweep stays bit-
identical. **Full spec + the piece-by-piece build list lives in `HANDOFF.md` → "NEXT PHASE — CARD CREATION
ENGINE".**
