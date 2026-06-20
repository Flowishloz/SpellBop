# WIZARD DODGEBALL — CARD FRAMEWORK (Authoring Guide)

> Master Context File. How the 51-card pool is AUTHORED and how the runtime
> resolves it. Updated by the Orchestrator at the close of the Round System
> sprint (2026-06-12). Companion to `Cards_Spells.txt` (the design spec this
> framework implements field-for-field).
>
> **DECK / ECONOMY MODEL (2026-06-19) → see `CONTENT_ENGINE.md`.** The 15-card
> deck (5 attack / 5 counter / 5 defense), the cooldown-cycle "draw", the
> build-time copy-limits, and the XP / pack / forge economy SUPERSEDE the older
> mana / draft model. This file stays the per-card AUTHORING + RUNTIME reference.

## THE ONE RULE
**Every card is a `.tres` of `CardResource` (`resources/card_resource.gd`).
Unique-feeling moves come from PARAMETERS, never bespoke card code.**
If a new card seems to need new code, it needs a new *parameter* (extend
`CardResource` + the relevant component), not a special case.

## THE THREE ARCHETYPE FLOWS (Creative Director, stack-rework sprint)
| Type | Cast | Flow |
|---|---|---|
| ATTACK | COMMITS ON PRESS (no channel/charge time) | press EDGE → **moment of no return**: the card SLAPS onto THE STACK (StackDisplay top-center, countdown window opens at 10% slow-mo, caster aims freely) → **the window expiring IS the release** (MatchController resolves the stack) → projectile fires from the caster's current position, homing per the card |
| DEFENSE | **INSTANT** tap (never on the stack) | one-way barrier deploys NOW (owner shoots through it); the **Window of Affect** is measured at deploy |
| COUNTER | tap **only while an enemy window is open** | SLAPS ONTO THE STACK overlapping the spell below — **the timer RESETS** (a new spell is on the stack). Its WOA is LATCHED at the slap. The stack resolves **LIFO** at expiry: the counter's frost wave fires before the attack it answered |

Because MatchController releases the stack on `stack_closed`, the on-screen
countdown and the release are the SAME event — the timer cannot lie.
COOLDOWNS: per-slot, 4 s, starting at the stage/deploy; cooling cards dim in
the hand. Under the deck system (below) the cooldown now DRIVES the cycle: when
a slot's cooldown ends, the slot advances to the next card of its type.

## DECK & DRAW — the loadout system (2026-06-19, see `CONTENT_ENGINE.md`)
The 3 slots are no longer single cards — they are the 3 TYPE-CYCLES of a
15-card deck (5 ATTACK / 5 COUNTER / 5 DEFENSE); the hand of 3 shows the
"current" card of each type. The existing card-pop IS the draw: on use +
cooldown, a slot CYCLES to the next card of its type (sequential index
0→1→2→3→4→0 — deterministic, no RNG to sync; the index is NEW saved sim-state).
Deck-build copy limits (UI-enforced): 5× same Common, 3× same Uncommon, 1× same
Rare. The deck is SNAPSHOTTED into `CardCasterComponent` at match start
(offline: player deck vs default AI deck; online: both decks exchanged at the
handshake) and only the integer index changes thereafter — so it stays
rollback-safe. NO mana, NO draft-choice (both cut after playtesting).

## WINDOW OF AFFECT (WOA) — risk vs reward timing
A 0..1 quality score for instant casts; it can scale ANY card attribute.
- **Defense WOA** = how close the nearest incoming ball is at deploy
  (`woa_range` away = 0, touching you = 1). The barrier **CAPTURES** the
  first hostile ball, holds it charging on the wall for
  `woa x woa_max_hold_seconds` (camera shake builds — the Lethal-Company
  anticipation beat), then reflects it at `1 + woa x (woa_max_reflect - 1)`
  times its speed with a `woa x woa_ricochet` lateral kick. The ricochet's
  left/right "random" sign is a parity hash of the capture position —
  deterministic on every peer. Your own throws just bounce (walls cut both
  ways — don't fire through your own bulwark).
  - *Sprint 23 (variable shield):* the capture HOLD is now a deterministic
    **reflect-intensity** blend of the WOA **and** the incoming ball SPEED
    (`barrier_controller.gd` — `_woa_fp` + `_captured_speed_fp` vs
    `capture_ref_speed`, split by `capture_speed_weight`), driving a tick-based
    hold (`capture_hold_min_ticks`..`capture_hold_max_ticks`, saved key `"ct"`)
    instead of `woa x woa_max_hold_seconds`; the same intensity (emitted on
    `capture_started`) scales the whole presentation beat (displacement-wave
    size/speed, slow-mo depth, rumble, release slam). The displacement wave now
    fires on **every** block (wired on spawn, rollback-safe). The reflect
    speed/ricochet model above is unchanged.
- **Counter WOA** = `1 - window_fraction_remaining` (TheStack) — countering
  just before the enemy spell releases scores ~1. The baseline frost wave
  maps WOA → slow strength (`slow_scale_weak` → `slow_scale_strong`).

## DATA MODEL
`CardResource extends SpellResource extends Resource` — data-only; one .tres
shared by both players and every rollback re-simulation.

| Block | Fields |
|---|---|
| Identity | `card_type`, `faction`, `rarity`, `casting_cost` 1–3, `is_reactive_only`, `description` (HUD rules text + damage) |
| Art | **`card_art`** (raw illustration — the Card Creation Engine face, assembled under the universal frames), `ui_sprite`, `world_sprite` |
| Rarity anim hooks | `cast_vfx_scene`, `cast_animation_name`, `screen_shake_intensity` (Rare = screen-shaking) |
| Attack (A) | inherited ballistics + `lifetime`, `projectile_count`, `spread_x_speed`, `stage_ticks` (countdown length in SIM ticks; 15 @ 10% = 2.5 real s) |
| Defense (B) | `barrier_scene`, `wall_size`, `wall_lifetime`, `wall_movement_speed`, `wall_offset_y`, WOA: `woa_range` / `woa_max_reflect` / `woa_max_hold_seconds` / `woa_ricochet`, + spec fields (`is_exploding`*, `rebound_window`*, `healing_absorb`*) |
| Charging-synergy (B sub) | `cast_while_charging`*, `movement_dash_distance`*, `conditional_draw`* |
| Counter (C) | `projectile_scene` (the wave), WOA: `slow_duration` / `slow_scale_weak` / `slow_scale_strong`, + spec fields (`opportunity_window`, `speed_modifier`, `teleport_distance`*, `freeze_duration`*, `phase_immunity`*) |

\* = data landed per spec; runtime effect arrives with later cards.

## CARD CREATION ENGINE (visual assembly — shipped 2026-06-20)
Card art is DROP-IN + procedurally assembled (mirrors the wizard skin pipeline):
one raw `card_art` PNG per card + three UNIVERSAL frame PNGs
(`res://resources/cards/frames/border_pill|in_round|full.png`) + a procedural
rarity icon. The deck-builder pill tiles, the Collection grid (full vertical
cards), the in-round card (`scenes/match_card_ui.tscn`, strict 5:7), and the Big
Inspect all crop the art + lay the frame + draw the text automatically, with
procedural fallbacks (type glyph / cyan & gold placeholder frames) so nothing
looks broken before art exists. Helpers: `scripts/ui/{rarity_icon,type_glyph_icon,
placeholder_border}.gd`. Authoring SOP: `resources/cards/card_instructions.txt`.
ALL UI sizes / fonts / colors / copy-limits / frame paths are tabulated in
`docs/DECK_BUILDER_FRAMEWORK.md` §11 TUNABLE PARAMETERS. Presentation only — never
read by the sim (determinism sweep stays bit-identical).

## PARAMETER SURFACE — WIRED vs DATA-ONLY (what's free vs needs code)
*(Verified 2026-06-19 against the resources + consuming components.)* The ONE
RULE — moves come from parameters — holds for almost the whole COMMON/UNCOMMON
pool. Author those as pure `.tres`, NO code:

- **Ballistics (all cards):** `base_speed`, `damage`, `projectile_size`,
  `bounciness` (wall-ricochet retention → multi-bounce trick shots), `cast_time`,
  `element` (Fire/Spark/Ice impact colour), `projectile_scene`.
- **ATTACK:** `lifetime`, `projectile_count` (1–5, auto-fanned), `spread_x_speed`,
  `stage_ticks`, `homing_strength` (0–1 seek), `barrier_breaker` (shatter+split).
- **DEFENSE:** `wall_size`, `wall_lifetime`, `wall_movement_speed` (drifting
  walls), `wall_offset_y`, + full WOA (`woa_range` / `woa_max_reflect` /
  `woa_max_hold_seconds` / `woa_ricochet`).
- **COUNTER:** `slow_duration`, `slow_scale_weak`/`strong`, `speed_modifier`.
- **Per-card presentation:** `card_art` (the Card Creation Engine illustration —
  drop a PNG into the slot), `screen_shake_intensity`, `cast_vfx_scene`,
  `cast_animation_name`, `ui_sprite`, `world_sprite`.

**DECLARED but NOT wired anywhere in `scripts/` → need NEW RUNTIME CODE:**
`is_exploding`, `rebound_window` (Perfect-Parry), `healing_absorb`,
`cast_while_charging`, `movement_dash_distance`, `conditional_draw`,
`teleport_distance`, `freeze_duration`, `phase_immunity`. These are the EXOTIC
mechanics — **RARES will generally need new wiring AND likely brand-new
parameters** (+ bespoke `cast_vfx_scene` / shake) to feel distinct from the
param-tuned commons/uncommons. Budget each Rare as a small mechanic feature,
determinism-checked individually — a Rare is NOT a pure `.tres`.

## RUNTIME MAP
| Piece | File | Role |
|---|---|---|
| CardCasterComponent | `scripts/player/components/card_caster_component.gd` | 3 slots, attack press→stage, instant D/C on press edge, reactive lock, WOA measurement. Sim state `{"cd","st","sr","pr"}` |
| BarrierController | `scripts/arena/barrier_controller.gd` + `scenes/barrier.tscn` | WALLS-layer wall + WOA capture/hold/release (signals: capture_started/charging/released) |
| Frost wave | `scenes/ice_wave.tscn` (FireballController + rect HitDetection extents) | 400-unit-wide, 1600 u/s, damage 0, timed slow payload (`slow_ticks`/`slow_scale_fp`) |
| Timed slow | `MovementComponent.apply_timed_slow` (sim state `"slt"/"sls"`) | min-composes with caster penalties; `IceCubeVFXComponent` renders the cube + countdown |
| Rounds | `core/match_controller.gd` | Bo3 (`rounds_to_win` 2), KO → 15 s post-round (hand expands) → reset via `PlayerController.reset_for_round`; victory + rematch |
| Hand UI | `scripts/ui/card_hand_hud.gd` | fanned dock / staged flight + countdown / post-round expanded — all wall-clock springs |
| Input | `InputCommand.KEY_CARD` (`"k"`) | keys 8/9/0; instant casts fire on the PRESS EDGE (previous slot saved as sim state `"pr"`) |

## STACK / SLOW-MO RULES
1. Any staging (attack OR counter slap) → `TheStack.open_window()` — opening
   AND refreshing resets the 2.5 s countdown. CPUParticles inherit the
   dilation; UI/camera shake run wall-clock.
2. `stack_closed` → MatchController resolves its `_stack_entries` LIFO via
   each caster's `release_staged()` (skipped if the round just ended — KO
   sets the match state BEFORE closing the window).
3. Counters can only START during a window (`card_rejected` otherwise);
   `1 - TheStack.window_fraction_remaining()` at the slap = their WOA.
4. StackDisplayHUD (`scripts/ui/stack_display_hud.gd`) renders BOTH players'
   staged cards top-center — big/legible, slapped-on overlap, shared
   countdown on the top card; entries fly off at resolution.

## MOVEMENT TECH
- **DASH (Left Shift / `InputCommand "d"`):** press edge + held direction →
  35% of the arena width in 10% of the normal travel time (3 ticks), 5 s
  cooldown, then a 90% slow for 0.8 s (own sim field — never triggers the
  frost ice cube). All state in MovementComponent
  (`"dt","dd","dcd","dsl","pd"`). HUD: `dash_button_hud.gd` — translucent
  circle + chevrons + clock-fill + seconds readout (bottom-left).
- **HOMING (`CardResource.homing_strength`):** per-tick fixed-point steering
  toward the enemy wizard (strength x 3 / tick_rate blend). Arcane Bolt =
  0.2 (a gentle seeking arc). Cleared when a barrier captures/reflects.

## AUTHORING A NEW CARD (checklist)
1. Duplicate the closest baseline `.tres` in `resources/cards/`.
2. Set Identity (type/faction/rarity/cost; counters: `is_reactive_only = true`)
   and write the `description` (include damage).
3. Tune ONLY the parameter block for its category. `is_card = true` always.
4. Register it in the card pool / `PlayerProfile` inventory so it can be
   collected and slotted into a deck. (Historically the 3 slots were hardcoded
   on `player.tscn`'s CardCasterComponent; under the deck system the caster is
   fed the deck at match start — see `CONTENT_ENGINE.md` §4.)
5. Run `tests/test_card_system.gd` + `tests/test_round_flow.gd` headless,
   then playtest with 8/9/0.

## BASELINE CARDS (pure archetypes, all cost 2, 4 s cooldown)
| Card | Key | Type | Numbers |
|---|---|---|---|
| Arcane Bolt (RED) | 8 | ATTACK | 700 u/s, DMG 2, 20% homing, lifetime 2.8 s |
| Verdant Bulwark (GREEN) | 9 | DEFENSE | 300x40 one-way wall, 3 s, WOA reflect up to 2.5x |
| Frost Front (BLUE) | 0 | COUNTER | 1600 u/s court-wide wave, 0 DMG, 3 s slow (0.6→0.3 by WOA) |

## DETERMINISM NOTES
- Stage/window-of-hold math is whole sim ticks; card floats convert
  to 64.16 fixed-point ONCE at cast time.
- Press edges derive from the PREVIOUS tick's input, stored as sim state
  (`"pr"`) — never from presentation.
- The reactive lock + counter WOA now read `StackResolver`'s tick-counted,
  all-int `window_fraction_fp` (Sprint 22 Phase 2a) — NOT `TheStack`'s wall
  clock, which is presentation-only. Stack resolution fires on a counted sim
  tick (identical on both peers); `TheStack` only paces the slow-mo.
- Card spawns are ROLLBACK-ROUTED (Sprint 22 Phase 2b): attack / counter /
  defense resolve through `SyncManager.spawn` with int/path payloads, each
  entity rebuilt by its `_network_spawn(data)` on spawn AND every rollback
  re-sim — so cards cast correctly online (Phase 2c).
- The barrier's "random" ricochet is a position parity hash; the AI's missed
  blocks are a tick % 3 gate — zero RNG anywhere.
- Shape sub-resources are DUPLICATED before runtime mutation (graveyard rule).
