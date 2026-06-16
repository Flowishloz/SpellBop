# Custom 2D Sprite Framework — SOP & Technical Reference

The wizard characters use a **bespoke "key-pose" pipeline**: hand-drawn static 128×128 sprites,
recoloured at runtime by a **palette-swap shader**, billboarded into the 3D arena, and swapped
per animation state on top of the existing **procedural** motion (squash/stretch/bob/recoil).

This document has two halves:

- **Part 1 — For the Artist** (you, drawing in Aseprite): how to draw, name, and drop art, and
  how to make new skins.
- **Part 2 — For Future AI** (a developer instance asked to extend the system): how the
  architecture actually works, and the **hard rules** that must never be broken.

Shipped in commits `6341342` (frame pipeline) + `4e521fa` (directional + premium skins), branch
`feature/spawn-rollback-cards`. The whole system is **presentation-only** (see §2.5).

---

# PART 1 — FOR THE ARTIST

## 1.1 Canvas & art rules

| Rule | Value | Why |
|------|-------|-----|
| **Canvas size** | **128 × 128**, square | The rig + hitbox are tuned for square frames. |
| **Colours** | **FLAT colours, NO shading, NO anti-aliasing** | The shader recolours by matching exact pixel colours. AA/gradient edges create off-palette colours that won't recolour cleanly. Hard-edged pixel art only. |
| **Palette size** | **≤ 16 colours** per wizard | The shader has 16 colour slots (`MAX_COLORS`). |
| **Feet** | Plant the feet near the **bottom row** of the frame | The engine plants the feet on the floor; a wizard drawn floating mid-frame will float in-game. |
| **Fill** | Fill most of the frame **height** with the character | Sets the on-screen size (~2 m tall). |

> Shading **is** allowed visually — just paint it as **distinct flat colours** (e.g. `robe`,
> `robe_dark`, `robe_light` as 3 separate palette entries), not soft gradients. That's how the
> placeholder art already does it.

## 1.2 The reference palette (the colours you paint with)

There is **one shared "reference palette"** — the exact set of hex codes every base sprite is
drawn in. It lives in the **base skin resource**:

```
res://assets_final/skins/default_blue.tres   →  its `colors` array IS the reference palette
```

The current placeholder reference palette (8 colours — you may grow it to 16):

| # | Role | Hex |
|---|------|-----|
| 0 | outline | `#1A1426` |
| 1 | robe (main) | `#3B5DC9` |
| 2 | robe (shadow) | `#2A3D8F` |
| 3 | robe (light) | `#6B8CFF` |
| 4 | skin | `#F0C9A0` |
| 5 | skin (shadow) | `#C98F6B` |
| 6 | hat star / accent | `#FFD34D` |
| 7 | eye / white | `#F5F5F5` |

**To use your OWN palette:** open `default_blue.tres`, set its `colors` to your chosen hex codes
(keep a **fixed order** — that order is the index every skin remaps by), and paint **all** base
art using exactly those colours. Save your Aseprite palette file so you stay on-palette.

> **Off-palette colours pass through untouched.** A spell orb, a glow, an effect colour that is
> *not* in the reference palette is rendered as-drawn on every skin — so spell colours don't
> change when the wizard's robe does. Use this deliberately.

## 1.3 Poses: names, front/back, where to drop them

Drop PNGs here:

```
res://assets_final/sprites/wizards/
```

**Every pose needs two files** — the wizard faces *down-court at the opponent*, so you see the
**back** of the near wizard and the **front** of the far one:

```
<pose>_front.png   ← faces the camera (draw the face)
<pose>_back.png    ← faces away      (draw the back of the head / a hood, no face)
```

The poses the game currently shows (one `_front` + one `_back` each):

| Pose file stem | When it shows |
|----------------|---------------|
| `idle` | standing still |
| `running` | moving left/right |
| `charging` | winding up a fireball |
| `cast_fire` | firing a fireball / red attack card |
| `cast_ice` | firing the counter / frost wave |
| `cast_shield` | deploying the shield/barrier |
| `hurt` | taking a hit (also held through the death fling) |
| `close_call` | a ball *barely* whizzes past without hitting |
| `cast_spark` *(optional)* | spark-bolt casts — if absent, falls back to `cast_fire` |

**Shortcuts & rules:**
- A no-suffix `idle.png` (no `_front`/`_back`) fills **both** facings — fine for a quick test, but
  the back will then show the face.
- Missing a file? The loader falls back **front ↔ back ↔ idle**, so the wizard never goes blank.
  You can replace poses **one at a time**.
- `flip_h` (left vs right lean) is **automatic** — you do **not** draw separate left/right art. One
  `_front` + one `_back` covers all four facings.

## 1.4 Seeing your art in-game (the auto-loader)

A small editor plugin watches the folder. **Just drop the PNG in** — when the Godot editor is
open it auto-registers within a second. If it doesn't pick up:

> Press the **"Rescan Wizard Poses"** button in the editor toolbar.

That's it. No code, no scene edits. (It rebuilds a small manifest file — leave that alone.)

## 1.5 Make a Color-Swap skin (a recolour)

This is the cheap, common skin — same shapes, new colours (the blue vs red wizards are exactly
this).

1. **Duplicate** `res://assets_final/skins/default_blue.tres` → e.g. `frost_knight.tres` (in the
   same `skins/` folder). (In Godot: right-click → Duplicate, or copy the file.)
2. Open it and set:
   - `id` — a unique key, e.g. `&"frost_knight"`.
   - `display_name` — shown in the wardrobe, e.g. `"Frost Knight"`.
   - `colors` — **one colour per reference slot, SAME count + SAME order** as the reference
     palette. Each entry recolours the matching reference colour (slot 1 = robe, slot 2 =
     robe-shadow, …). Leave `texture_folder_override` **empty**.
   - `price` — `0` = free/default; any number = a shop price tag.
3. Done. Assign it to a wizard's **WizardAnimator → `skin`** in the scene, or it will be selectable
   once the wardrobe screen lists it.

## 1.6 Make a Premium (geometry) skin (a new shape)

A premium skin changes the **silhouette** — a different hat, a different body — not just colours.

1. **Make a folder:** `res://assets_final/skins/<name>/` (e.g. `skins/cyber_wizard/`).
2. **Draw the new art** into it as `<pose>_front.png` / `<pose>_back.png` — same 128×128 rules,
   **and still painted in the reference palette** (slot 1 still = the colour you want recoloured as
   "robe", etc.). You don't need every pose; missing ones fall back to *that folder's* `idle`.
3. **Make the skin resource** `res://assets_final/skins/<name>.tres` (duplicate a skin again) and
   set:
   - `texture_folder_override` → the folder path, e.g. `"res://assets_final/skins/cyber_wizard/"`.
   - `colors` → the recolour you want (because the premium art is still drawn in the reference
     palette, the shader **also recolours it**). Want shape-change only, no recolour? Set `colors`
     equal to the reference palette.
   - `id`, `display_name`, `price` as usual.

> **Worked example already in the repo:** `cyber_wizard.tres` (the CD's "neon wizard") →
> `texture_folder_override = res://assets_final/skins/cyber_wizard/` (a wide hat) + a teal
> `colors` recolour, `price = 500`.

## 1.7 Artist quick-checklist

- [ ] 128×128, flat colours, no AA, feet at the bottom.
- [ ] Painted in the reference palette (`default_blue.tres` `colors`), ≤16 colours.
- [ ] Two files per pose: `<pose>_front.png` (face) + `<pose>_back.png` (no face / hood).
- [ ] Dropped in `assets_final/sprites/wizards/` (or a skin's own folder for premium).
- [ ] Saw it update in-editor (or hit "Rescan Wizard Poses").

---

# PART 2 — FOR FUTURE AI (THE ARCHITECTURE)

You are likely here because someone asked you to **add a pose state**, **add a skin feature**, or
**touch the wizard visuals**. Read §2.5 first — it is the rule that protects the game.

## 2.1 System map

```
assets_final/
├─ palette_swap.gdshader ............ recolour + re-implements the FIXED_Y billboard (§2.4)
├─ sprites/wizards/ ................. base pose art  <pose>_front.png / _back.png
│   └─ wizard_pose_manifest.tres .... GENERATED facing-aware index (do not hand-edit)
└─ skins/
    ├─ default_blue.tres ............ identity skin; its `colors` == the REFERENCE palette
    ├─ default_red.tres ............. recolour skin
    ├─ cyber_wizard.tres ............ PREMIUM skin (texture_folder_override) + its art folder/
scripts/visual/
├─ wizard_animator_component.gd ..... the brain: pose state machine, facing, skin upload (§2.2)
├─ skin_palette.gd .................. SkinPalette Resource (id, display_name, colors, price,
│                                      texture_folder_override)
├─ wizard_pose_library.gd .......... runtime loader: get_pose(pose, facing, folder) (§2.3)
├─ wizard_pose_manifest.gd .......... the manifest Resource schema
└─ skin_catalog.gd ................. SkinCatalog: export-safe skin registry (load-by-path list +
│                                      owned/price/currency placeholder metadata) — the cosmetics
│                                      carousel/locker enumerate skins through this (shipped 4665f56)
addons/wizard_pipeline/plugin.gd .... @tool EditorPlugin: auto-watch + manifest gen (§2.3)
scenes/player.tscn .................. Sprite3D (palette_swap material_override) + WizardAnimator
scenes/cosmetics.tscn ............... wardrobe/shop scene (CanvasLayer UI over a Node3D diorama);
│                                      cosmetics_wizard.tscn = a visual-only player.tscn trim on the
│                                      podium, facing_override=&"front" (the set_skin/SkinCatalog
│                                      consumer; shipped 4665f56)
tests/
├─ gen_wizard_placeholders.gd ....... regenerates the placeholder art + 3 skins + manifest
├─ probe_billboard_override.gd ...... proves material_override drops the native billboard
├─ probe_facing_check.gd ............ headless: asserts player→idle_back, opponent→idle_front
└─ probe_two_wizards.gd ............. renders blue/red/premium side by side
```

**Data flow each frame:** `WizardAnimator._process` picks a pose name (state machine) + a facing
→ `WizardPoseLibrary.get_pose(pose, facing, skin_folder)` returns a `Texture2D` → assigned to
`Sprite3D.texture` **and** the shader's `pose_tex` uniform → `palette_swap.gdshader` billboards
the quad and recolours the pixels. The procedural squash/stretch/bob runs **underneath**,
independently, on the rig transform.

## 2.2 `wizard_animator_component.gd`

**It is a plain `Node`. It has NO `_save_state`/`_load_state`, is NOT in `network_sync`, and never
writes sim state.** It reads signals + visual transforms and drives only the Sprite3D texture,
`flip_h`, the rig Y/roll/scale, and sprite modulate.

### State machine — `_select_pose_name(now, speed)`
Strict priority (first match wins):

```
hurt        if now < _hurt_until_msec        (set in _on_damaged / _on_slowed)
close_call  if now < _close_call_until_msec  (set by the proximity scan, below)
cast        if now < _cast_until_msec        (pose = _cast_pose; set in _on_cast_released)
charging    if _charging                     (cast_charge_started/_canceled)
running     if speed > run_pose_speed        (speed = |Δ rig.x| per frame, visual only)
idle        otherwise
```

The momentary poses (hurt/cast/close_call) are **timed windows** (`pose_hold_seconds`, default
0.25 s). `_cast_pose` is chosen by element in `_cast_pose_for(spell)`: `DEFENSE → cast_shield`,
else `FIRE → cast_fire`, `SPARK → cast_spark` (falls back to `cast_fire` if absent), `ICE →
cast_ice`.

### `flip_h` (left / right)
Set every frame from the visual X velocity sign (`dir`):
```gdscript
_sprite.set(&"flip_h", (dir < 0) if face_art_default_right else (dir > 0))
```
This mirrors whichever front/back texture is showing. It is purely the lean direction — **not**
front/back.

### Front / back facing (`_facing`)
The wizard faces its opponent down-court. It shows its **BACK** when that points away from the
camera (near side), **FRONT** when toward it (far side):
```gdscript
var flip_z: bool = _bridge != null and _bridge.view_flip_z
_facing = &"front" if (_cast_dir * (-1 if flip_z else 1)) > 0 else &"back"
```
- `_cast_dir` = a sibling caster's `cast_direction_y` (P1 = −1 near, P2 = +1 far), read once in
  `_ready`.
- `view_flip_z` = the **online perspective mirror** on the sibling `VisualBridgeComponent`. The
  client renders the court flipped so the local wizard is near; folding `view_flip_z` in makes the
  facing **perspective-correct on both peers** (each sees its own wizard's back + the foe's front).
- Grounding geometry: player spawns sim-Y +880 → world-Z +8.8 (near); opponent −880 → −8.8 (far);
  camera at Z +12.6 behind the player.

> **Menu / podium gotcha (SOLVED — `facing_override`):** a wizard in a menu diorama has **no
> caster and no VisualBridge** → `_cast_dir` defaults −1, `_bridge` is null → the match-driven
> facing above computes to **back**. For a front-facing wizard outside a match (e.g. the wardrobe
> podium) use the **`facing_override` export** (+ the `set_facing(StringName)` setter) on
> `wizard_animator_component.gd` — shipped in commit `4665f56`. It is **presentation-only**: the
> default `&""` preserves the exact match-driven facing (so a real match stays byte-identical), and
> a non-empty value (`&"front"` / `&"back"`) forces that facing instead. The cosmetics podium rig
> `cosmetics_wizard.tscn` sets `facing_override = &"front"`.

### Skins & texture
- `_apply_skin()` uploads `src_colors = base_skin.colors` (the reference) and `dst_colors =
  skin.colors` (the active recolour) to the material; `color_count = 0` means identity passthrough.
- `_apply_pose(pose)` = `WizardPoseLibrary.get_pose(pose, _facing, _skin_folder)` → set
  `_sprite.texture` + the `pose_tex` uniform (only when the texture actually changes).
- **Per-instance material:** `_ready` **duplicates** the `material_override` so the two wizards
  (opponent.tscn instances player.tscn → shared sub-resource) don't fight over `pose_tex`/palette.
- `set_skin(new_skin)` swaps recolour + premium folder at **runtime** (the wardrobe/shop hook):
  it re-uploads the palette and clears the texture caches so the next frame re-fetches.

### Exposed tuning knobs (`@export`)
`skin`, `base_skin`, `projectile_container_path`, `body_half_width` (52.5), `close_call_margin`
(80.0), `pose_hold_seconds` (0.25), `run_pose_speed` (0.6), `face_art_default_right` (true) — plus
the inherited procedural knobs (lean, bob, flicker, hit-pop, death). **On-screen size** is the
`Sprite3D` `pixel_size` (0.0164) + local Y-offset (1.05) in `player.tscn`, *not* the animator.

## 2.3 The auto-watch plugin + manifest + loader fallback

`addons/wizard_pipeline/plugin.gd` — an `@tool EditorPlugin`, enabled in
`project.godot [editor_plugins]`:
- On `EditorFileSystem.filesystem_changed` (and via a **"Rescan Wizard Poses"** toolbar button) it
  scans `assets_final/sprites/wizards/*.png`, groups by suffix (`_front` / `_back`; a no-suffix
  name fills both), and writes `wizard_pose_manifest.tres` (`pose_names` / `front_paths` /
  `back_paths`, parallel arrays). It **saves only when the content changed** — that guard is what
  stops the save→`filesystem_changed`→save infinite loop. Then it calls `WizardPoseLibrary.reload()`.

`WizardPoseLibrary.get_pose(pose, facing, folder)`:
- `folder == ""` (**base**): reads the **manifest** (the export-robust path); if the manifest is
  missing it falls back to a live `DirAccess` scan (editor/desktop only).
- `folder != ""` (**premium**): loads by **constructed path** `folder/<pose>_<facing>.png` (no
  directory listing → works in exported builds), caching negatives too.
- **Fallback chain:** requested facing → other facing → `idle` same facing → `idle` other facing →
  `null` (animator keeps its current texture).

> **WHY a manifest exists:** `res://` *directory listing* is unreliable in exported mobile builds,
> but `load("res://…png")` *by path* is reliable. So the base set uses a committed manifest, and
> premium folders use load-by-path. **Never** rely on `DirAccess` listing at runtime in shipped code.

## 2.4 `palette_swap.gdshader` — the forced FIXED_Y billboard

**Critical fact (empirically verified by `tests/probe_billboard_override.gd`: a 70° yaw
foreshortened the quad to cos70 ≈ 0.35):** putting a `ShaderMaterial` in a `Sprite3D.material_override`
**REPLACES the node's built-in billboard.** The sprite stops facing the camera. So the shader
**re-implements** Godot's own FIXED_Y *keep-scale* billboard in `vertex()`:

```glsl
void vertex() {
    // Rebuild the camera-facing basis (faces camera around world-Y, stays upright).
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
        vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
        MODEL_MATRIX[3]);                       // <- translation preserved (bob, world pos)
    // Re-apply node SCALE as positive magnitudes so squash/stretch + the death width-pulse survive.
    MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
        vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
        vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
        vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
        vec4(0.0, 0.0, 0.0, 1.0));
    MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
```

Consequences you must preserve if you edit this shader:
- **Translation** (`MODEL_MATRIX[3]`) is kept → the bob and world position work.
- **Scale** is re-applied via `length(MODEL_MATRIX[col])` → the procedural squash/stretch and the
  death flat-spin (which oscillates `scale.x` to a width-pulse) still read. The magnitude is
  positive, so a **negative** scale (mirror) and any node **rotation** are dropped — the running
  lean (`rig.rotation.z`) was *already* a no-op under the native FIXED_Y billboard, so this matches
  prior behaviour exactly.

**Fragment** — colour-match recolour:
- Samples `pose_tex` (`: source_color, filter_nearest`), converts back to **sRGB**, and matches
  each pixel against `src_colors[i]` within `match_eps`; a hit outputs `dst_colors[i]`, else
  passthrough. **Matching is done in sRGB on purpose** — linear space collapses dark shades
  together and would alias them. Output is converted back to linear and multiplied by `COLOR`
  (the sprite's modulate → the damage flash / death fade still tint it). `ALPHA = tex.a * COLOR.a`.
- `MAX_COLORS = 16`, `render_mode unshaded, cull_disabled`.

## 2.5 ⚠️ THE DETERMINISM RULE — read before any change

The game is a **rollback-netcode** title. The simulation is deterministic, fixed-point, and lockstep
across peers. **The 20/20 headless test suites assert the sim is BIT-IDENTICAL.** The entire
character-visual system exists **outside** that sim, and it must stay that way:

1. **No sim writes, ever.** Visual code may *read* sim positions (the `close_call` scan reads
   `get_global_fixed_position()`), but must **never** write sim state, and must **never** add
   `_save_state` / `_load_state` / `network_sync` membership / `_network_process` to a visual node.
2. **Guard every signal-driven visual hook with `is_in_rollback()`.** Sim signals (`damaged`,
   `slow_started`, `knocked_out`, `spell_cast`, spawns) **re-fire on every rolled-back re-sim**. An
   unguarded hook re-stamps cosmetics or double-spawns particles. The idiom (already on
   `_on_damaged`/`_on_slowed`/`_on_knocked_out`):
   ```gdscript
   if SyncManager != null and SyncManager.is_in_rollback():
       return
   ```
   This was a real bug — fixed in commit `448bc75`. Render-rate work in `_process` is inherently
   safe (it doesn't run during a rollback re-sim), but guard it anyway for clarity (the `close_call`
   scan does).
3. **The test is the proof.** After ANY visual change, run the full 20-suite headless sweep. It
   **must stay 20/20 bit-identical.** If a fingerprint shifts, your change touched the sim — find
   it and move it back to the presentation side. (Also run `--headless --import` and at least one
   screenshot/headless probe.)

If you cannot make a feature work without touching saved/sim state, **stop and escalate** — it does
not belong in this pipeline.

## 2.6 Worked example — "add a new pose state" (e.g. `taunt`)

1. **Art:** the artist drops `taunt_front.png` + `taunt_back.png` into
   `assets_final/sprites/wizards/`. The plugin registers them automatically — **no loader/manifest
   code changes** (that's the whole point of the dynamic loader).
2. **Trigger:** decide what makes the wizard taunt. If it's a **sim signal** (e.g. on a KO win),
   connect it in `_ready` and set a timed window in the handler — **guarded by `is_in_rollback()`**
   (§2.5):
   ```gdscript
   var _taunt_until_msec: int = 0
   func _on_round_won() -> void:
       if SyncManager != null and SyncManager.is_in_rollback(): return
       _taunt_until_msec = Time.get_ticks_msec() + int(pose_hold_seconds * 1000.0)
   ```
   If it's input/menu-driven, set the window from `_process` instead (no guard needed).
3. **Priority:** add one branch to `_select_pose_name`, in the right priority slot:
   ```gdscript
   if now < _taunt_until_msec:
       return &"taunt"
   ```
4. **Reset:** clear `_taunt_until_msec` in `_on_health_changed` (the round-reset path), beside the
   other `_*_until_msec` resets.
5. **Verify:** `--import`, then the 20-suite sweep stays **20/20 bit-identical** (it will — this is
   all presentation), then eyeball a screenshot probe.

No shader, scene, or manifest edits are required. Element-keyed cast variants go through
`_cast_pose_for` / `_elem_pose` instead.

## 2.7 Verification recipe

```powershell
# 1. Parse + import (run after adding scripts / art / class_names)
<godot-4.6.3-console> --headless --path . --import

# 2. Headless facing/texture logic check
<godot> --headless --path . -s res://tests/probe_facing_check.gd
#   expect: player -> idle_back | opponent -> idle_front | cyber -> cyber_wizard/idle_front

# 3. The determinism gate — MUST be 20/20 bit-identical (run suites SEQUENTIALLY; parallel
#    deadlocks on the .godot import cache). See the sweep recipe in the Brain.

# 4. Visual eyeball (needs a window/GPU, not --headless)
<godot> --path . -s res://tests/probe_two_wizards.gd     # blue back / red front / cyber premium
<godot> --path . -s res://tests/screenshot_probe.gd      # match_arena
```

Godot binary: `C:\Users\laure\Downloads\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe`
(4.6.3-stable — see the `godot-version-463` memory).

---

## Appendix — the three demo skins

| File | Kind | Notes |
|------|------|-------|
| `default_blue.tres` | base / identity | its `colors` **is** the reference palette; `base_skin` on every wizard points here |
| `default_red.tres` | colour-swap | robe slots remapped to crimson |
| `cyber_wizard.tres` | **premium (geometry)** | `texture_folder_override = res://assets_final/skins/cyber_wizard/` (wide hat) + teal recolour, `price = 500`. The CD calls this the **"neon wizard."** |

**Related Brain docs:** the build history is in `HANDOFF.md` and `Project_State.txt` — the
wardrobe/cosmetics scene SHIPPED in commit `4665f56` (`scenes/cosmetics.tscn` + `cosmetics.gd`,
the `facing_override` podium hook, and `SkinCatalog`), with persistence + equip→match still
deferred there. The billboard gotcha is also captured in the team memory
`sprite3d-material-override-billboard`.
