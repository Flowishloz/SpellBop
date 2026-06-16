## spell_resource.gd — Data definition for one castable spell (Custom Resource).
##
## ROLE: The foundational Custom Resource for the full 51-card pool
## (Cards_Spells.txt §1/§2). Sprint 2 carries only the fields the Base Fireball
## needs (Category A: Attack/Projectile); later sprints extend this resource —
## never hard-code spell stats in components.
##
## DATA-ONLY: This class holds tuning values and asset references. It contains
## NO simulation logic and NO mutable state — a single .tres can be shared by
## both players and by every rollback re-simulation safely.
##
## UNITS: floats here are human-friendly per-SECOND / sim-unit values. The
## consumer (SpellCasterComponent) converts them ONCE to fixed-point per-tick
## values in its _ready() — exactly like MovementComponent's tuning model.
class_name SpellResource
extends Resource

## Player-facing card name (UI, telegraph banner during the Stack window).
@export var display_name: String = ""

## The deterministic projectile scene the caster instantiates. Scene root must
## expose launch(velocity_x_fp, velocity_y_fp, bounciness_fp) and the standard
## SG fixed_position / sync_to_physics_engine() API (FireballController).
@export var projectile_scene: PackedScene

## Travel speed down-court, in sim units per SECOND (1 sim unit = 1 "pixel" on
## the SG2D plane). Converted to fixed-point units/tick once by the caster.
## Subject to the Manifesto's Terminal Velocity cap — enforced by the
## projectile's movement, not here.
@export var base_speed: float = 800.0

## Damage applied to the opponent's per-round health pool on hit.
## Baseline per the Manifesto: Base Fireball = 1, and 6 accumulated damage = KO.
@export var damage: int = 1

## Collision radius in sim units. The human sizes the projectile scene's
## SGCollisionShape2D (and sprite scale) to match this value by hand.
@export var projectile_size: float = 24.0

## Speed retained when reflecting off an arena wall: 1.0 = full speed kept,
## 0.5 = half speed after each bounce. Converted to fixed-point once by the
## caster and passed into launch().
@export var bounciness: float = 1.0

## TRUE for card spells: casting one goes "on the Stack" — telegraph UI plus
## the 10% time-slow window (Manifesto §2). FALSE for the baseline default
## attack (the zero-dead-state Base Fireball): it spawns silently with no
## telegraph and no time dilation. MatchController reads this on every cast.
@export var is_card: bool = false

## Seconds the cast input must be HELD before the projectile launches
## (Manifesto §2: casting slows movement and adds risk). 0.0 = instant cast.
## Converted once to whole ticks by the caster. While charging, the caster
## applies its movement speed penalty and fires its charge VFX signals.
@export var cast_time: float = 0.5

## VISUAL ELEMENT (Sprint 23 batch 2, Creative Director): drives the impact COLOUR of this spell's
## hits — Fire = orange, Spark = yellow, Ice = blue (one source of truth in scripts/visual/elements.gd,
## kept index-aligned with its FIRE/SPARK/ICE enum). PURE PRESENTATION: it rides the projectile's spawn
## payload as a small int ("elem") and is read ONLY by the hit VFX (burst, sprite flash, muzzle flash),
## never by sim math. Default Fire (the Base Fireball); the Spark Bolt + frost-wave .tres set Spark / Ice.
@export_enum("Fire", "Spark", "Ice") var element: int = 0
