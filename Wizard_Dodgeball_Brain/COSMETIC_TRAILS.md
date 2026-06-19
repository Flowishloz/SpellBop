# COSMETIC TRAILS — design note + expansion plan

> **Search tag: `cosmetic trails`.** Standalone note (deliberately NOT in the HANDOFF running log) so it
> stays out of the way until summoned. Mention "cosmetic trails" to find it.
>
> **Status (2026-06-19):** the runtime FOUNDATION + the first default trails are SHIPPED (branch
> `feature/gameplay-anim`, the particle-overhaul change). The catalog, the economy wiring, and the
> cosmetics-screen picker are the FUTURE task captured below.

## What a "Trail" is

A **trail** is the particle effect a wizard emits **while moving** — the movement-feedback VFX. Trails are
**movement-type specific**, because the two locomotion styles look different:

- **WALK trails** — for grounded sprites. The shipped default is the **footstep dust** (`DustParticles`).
- **HOVER trails** — for floating sprites (`GameSettings.hover_mode` / a future per-skin flag). The shipped
  default is the **trailing energy motes** (`HoverTrail`, world-space `local_coords=false` so motes stream
  behind as the wizard moves).

**Rule:** a walking sprite can NEVER wear a hover trail (and vice-versa). The runtime enforces this by
slotting a trail by its `movement_type` — the animator only ever drives the WALK slot for a grounded
sprite and the HOVER slot for a floating one, so a mismatched trail simply never plays.

> NOTE — trails are the ONLY walk/hover-specific particle. The DBZ **charge aura** (`CastParticles`,
> feet-up, driven by `CastChargeVFXComponent`) and the green **boon aura** (`BuffAura`) are identical on
> every skin; only the movement trail differs.

## What's built now (the seam)

- **`scripts/visual/trail_resource.gd`** — `TrailResource` (Resource): `id`, `display_name`,
  `movement_type` (WALK/HOVER), `emitter_scene` (a `CPUParticles3D`/`GPUParticles3D` scene), and
  cosmetic-economy fields (`price`, `currency`) for the future shop. **Presentation only** — a trail is
  pure VFX, never sim/saved state, so it has ZERO determinism constraint (it can never desync online).
- **`WizardAnimatorComponent.set_trail(trail)`** — the runtime equip hook. Instances the trail's
  `emitter_scene` under the rig and makes it the active emitter for its `movement_type` slot (freeing any
  prior instanced one); a trail with no `emitter_scene` reverts that slot to the baked default. The
  animator drives the active walk/hover trail node in `_update_aura_particles` (on while actually moving).
- **`@export var walk_trail` / `hover_trail`** on the animator (in `player.tscn`) — equipped trails;
  empty = the baked defaults (dust / motes). Applied at the end of `_ready`.
- **Defaults** live as baked nodes in `player.tscn` under `WizardRig`: `DustParticles` (walk),
  `HoverTrail` (hover).

So adding ONE alternative trail today already works: author a `TrailResource` `.tres` (set
`movement_type` + an `emitter_scene`) and call `animator.set_trail(it)`.

## Future task (the expansion — "overhaul the cosmetics screen")

1. **Catalog** — a `TrailCatalog` (mirror `SkinCatalog`): the list of `TrailResource`s with `owned`/price,
   a `DEV_UNLOCK_ALL` switch, `is_owned()`. Author several `.tres` per movement type (`emitter_scene`s).
2. **Persistence** — store the equipped trail PER movement type in `PlayerProfile` / `GameSettings`
   (`equipped_walk_trail` / `equipped_hover_trail` ids); apply on spawn (set the animator's `walk_trail`/
   `hover_trail` exports, or call `set_trail`). Same pattern as the equipped skin.
3. **Cosmetics screen overhaul** — add a **Trails** section to the cosmetics scene (`scenes/cosmetics.tscn`
   / `scripts/ui/cosmetics.gd`): show trails filtered by the previewed skin's movement type (so a walking
   skin only offers walk trails), preview on the podium wizard via `set_trail`, buy/equip through the
   economy. This is the bulk of the future work and pairs with the broader Content-Engine cosmetics arc
   (see `CONTENT_ENGINE.md`).
4. **Per-skin movement type** — today hover/walk is the global `GameSettings.hover_mode` debug toggle;
   the future model is **per-skin** (some skins hover, others walk — see the character-frame pipeline).
   When a skin declares its movement type, the equipped-trail filter + the animator's `_hover_active`
   should read THAT, not the global toggle.

## Determinism / safety

Trails are character-emitted CPU particles — presentation only. Nothing here is saved state, hashed, or
read mid-tick, so the determinism sweep and online play are unaffected by trail content. Keep it that way:
a trail must never feed sim state.
