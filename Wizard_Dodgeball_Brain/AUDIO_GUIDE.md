# WIZARD DODGEBALL — AUDIO GUIDE (Placeholder SFX)

> Master Context File. Every sound in the game, what triggers it, where the
> trigger lives in code, and how to replace it. Written by the Orchestrator
> at the close of Sprint 12 (2026-06-12).

## HOW IT WORKS
- All SFX live in **`res://audio/sfx/<name>.wav`**.
- The **`SoundFX` autoload** (`core/sound_fx.gd`) loads every file in its
  `NAMES` list at startup and exposes `SoundFX.play(&"name")` — one-shot,
  fire-and-forget, works while paused (UI clicks in the ESC menu).
- **REPLACING A SOUND = dropping your new .wav over the same filename.**
  No code changes needed. Adding a NEW sound = add the file + its name to
  `NAMES` in `core/sound_fx.gd` + a `SoundFX.play()` call at the trigger.

## LOUDNESS
The placeholders are synthesized and RMS-normalized to ≈ **−21 dBFS RMS**
(ballpark **−18/−20 LUFS** for these short one-shots — exact LUFS varies
with duration). When you replace them, master your files to **−18/−20 LUFS
integrated** and the in-game balance will carry over; per-call trim is
available via `SoundFX.play(&"name", volume_db)`.

## THE SET (15 files)

| File | Trigger | Code location | Placeholder character |
|---|---|---|---|
| `cast_fireball.wav` | Base fireball released (charge let go) | `core/match_controller.gd` → `_on_spell_cast` (non-card branch) | falling whoosh, noisy |
| `release_bolt.wav` | Staged ATTACK card resolves (bolt fires) | `core/match_controller.gd` → `_on_spell_cast` (is_card branch) | punchier, deeper whoosh |
| `stage_slap.wav` | Any card SLAPS onto the stack (attack staged / counter slapped) | `core/match_controller.gd` → `_on_spell_staged` | card-on-table thump |
| `shield_deploy.wav` | Verdant Bulwark wall raised | `core/match_controller.gd` → `_on_spell_cast` (barrier branch) | rising shimmer |
| `shield_capture.wav` | Wall CAPTURES a ball (WOA hold begins) | `scripts/arena/barrier_controller.gd` → `_try_capture` | crunch + pitch drop |
| `shield_release.wav` | Held ball flung back (WOA release) | `core/match_controller.gd` → `_on_capture_released` | springy rising zip |
| `counter_wave.wav` | Frost Front wave looses | `core/match_controller.gd` → `_on_spell_cast` (slow_ticks branch) | icy bell shimmer |
| `hit_wizard.wav` | Any wizard takes DAMAGE | `core/match_controller.gd` → `_on_wizard_damaged` | low thud |
| `frost_hit.wav` | Frost wave lands its slow (no damage) | `scripts/projectiles/fireball_controller.gd` → `_on_hit` | crystalline ring |
| `dash.wav` | Either wizard dashes (Shift) | `core/match_controller.gd` (wires `MovementComponent.dashed`) | fast airy zip |
| `wall_bounce.wav` | Ball bounces off an invisible side wall | `scripts/projectiles/fireball_controller.gd` → `_on_bounced` | tiny blip |
| `round_win.wav` | Round ends, player took it | `core/match_controller.gd` → `_on_knocked_out` | rising 3-note arp |
| `round_lose.wav` | Round/match ends, player lost it | `core/match_controller.gd` → `_on_knocked_out` | falling 2-note |
| `victory.wav` | Match won | `core/match_controller.gd` → `_on_knocked_out` | 4-note fanfare |
| `ui_click.wav` | Menu buttons (Story/gear), ESC toggle | `scripts/ui/home_screen.gd`, `scripts/ui/settings_menu.gd` | short tick |
| `tape_slow.wav` | Slow-mo ENGAGES (first staging; refreshes don't re-trigger) | `core/match_controller.gd` → `_on_spell_staged` (`_window_open_flag`) | tape grinding down, warbled descent |
| `stopwatch_tick.wav` | Each elapsed second of the stack countdown | `scripts/ui/stack_display_hud.gd` → `_on_stack_tick` | mechanical tick |
| `slap_on_card.wav` | A card lands ON TOP of another on the stack | `scripts/ui/stack_display_hud.gd` → `_on_staged` (layers over `stage_slap`) | sharper, brighter slap |
| `shield_shatter.wav` | A barrier-breaker bolt SHATTERS a wall | `scripts/arena/barrier_controller.gd` → `_shatter` | glass crack + ringing shards |

## NAMED HOOKS — NO PLACEHOLDER .wav YET (registered, silent until a file is dropped in)
> A name in `SoundFX.NAMES` with no matching `audio/sfx/<name>.wav` simply loads nothing and
> `SoundFX.play()` is a silent no-op — so the trigger can be wired ahead of the asset. Drop the
> `.wav` in (same filename) and it goes live with no code change. Heard with the regular pass.

| File (to add) | Trigger | Code location | Intended character |
|---|---|---|---|
| `knockout.wav` | A wizard is KNOCKED OUT (the lethal hit / death beat) — added with the Sprint 23 batch 2 hard-KO hitstop | `core/match_controller.gd` (the KO path / `_on_knocked_out`) | heavy impact + a downbeat thud; the "kill" punctuation, distinct from `hit_wizard`/`round_lose` |

## RETRIGGER BEHAVIOR
A retrigger of the SAME sound crossfades the previous instance out over
0.12 s (`core/sound_fx.gd` `_last_player` map). Different sounds layer
freely — replace-time mixes should assume polyphony.

## NOT YET COVERED (add with the audio pass proper)
- Charge-up loop (fireball hold) — needs a looping stream + start/stop on
  `cast_charge_started`/`cast_charge_canceled`/`spell_cast` (the signals
  already exist on both casters).
- Footsteps / movement bed, KO stinger separate from round jingles,
  home-screen ambience, frost-slow ongoing loop, confetti/podium fanfare
  layer on the new match-end screen.

## FORMAT NOTES
- WAV PCM 16-bit mono 44.1 kHz. Godot reimports automatically on focus;
  headless: run `--import` once after swapping files.
- Keep one-shots under ~1 s where possible; the dispatcher spawns a player
  per call with no voice limiting (placeholder-grade by design).
