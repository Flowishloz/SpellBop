## trail_resource.gd — a MOVEMENT-TRAIL cosmetic (the 'Trails' category). [search: cosmetic trails]
##
## A "trail" is the particle effect a wizard emits WHILE MOVING. Trails are MOVEMENT-TYPE SPECIFIC: a
## WALK trail only fits a grounded sprite, a HOVER trail only a floating one (a walking sprite can NEVER
## equip a hover trail). The shipped DEFAULTS are baked into the wizard scene — the footstep DUST is the
## default walk trail, the trailing energy MOTES (HoverTrail) the default hover trail. This resource is
## the data seam a FUTURE cosmetics pass uses to ship + equip ALTERNATIVE trails:
## WizardAnimatorComponent.set_trail() instances `emitter_scene` and slots it by `movement_type`.
##
## PRESENTATION ONLY — a trail is pure VFX (a particles node), never sim / saved state. See the design
## note Wizard_Dodgeball_Brain/COSMETIC_TRAILS.md for the planned catalog + cosmetics-screen expansion.
class_name TrailResource
extends Resource

enum MovementType { WALK, HOVER }

## Stable id — persistence / shop key.
@export var id: StringName = &""
## Shown in the (future) cosmetics picker.
@export var display_name: String = ""
## Which movement style this trail belongs to. WALK trails fit grounded sprites, HOVER trails floating
## ones — set_trail() slots by this, so a walking sprite only ever drives its WALK trail.
@export var movement_type: MovementType = MovementType.HOVER
## The trail's emitter: a scene whose ROOT is a CPUParticles3D (or GPUParticles3D), configured for the
## look. The animator instances it under the rig and toggles `emitting` while the wizard moves. Leave
## EMPTY to keep the scene's baked default emitter for this movement type (dust / motes).
@export var emitter_scene: PackedScene
## Cosmetic-economy metadata (mirrors SkinPalette) — wired to the shop / PlayerProfile by the future
## trails task; unused by the runtime today.
@export var price: int = 0
@export var currency: StringName = &"coins"
