## card_resource.gd — Data definition for one CARD (Custom Resource).
##
## ROLE: the card-pool half of the spell data model (Cards_Spells.txt §1/§2).
## Extends SpellResource — a card IS a castable spell (projectile fields,
## damage, is_card) plus the card-game identity (faction/rarity/cost) and the
## three category architectures: ATTACK, DEFENSE & UTILITY, COUNTER.
##
## DESIGN INTENT (Creative Director): every one of the 51 launch cards is
## authored as a .tres of THIS class — unique-feeling "moves" come purely from
## tweaking these parameters (Phantom Dust / MTG style), never from bespoke
## card code. Category fields not used by a card's type are simply ignored at
## runtime (e.g. wall_size on an ATTACK card does nothing).
##
## DATA-ONLY: tuning values and asset references. NO simulation logic, NO
## mutable state — one .tres is safely shared by both players and every
## rollback re-simulation. Consumers (CardCasterComponent and the effect
## components it arms) convert floats ONCE to fixed-point at _ready()/cast.
##
## RARITY ANIMATION CONTRACT (Cards_Spells.txt §5): COMMONS use the standard
## generic cast presentation. UNCOMMONS attach a minor bespoke animation via
## cast_vfx_scene / cast_animation_name. RARES go further — full custom
## presentation plus screen_shake_intensity feeding the camera trauma system.
## The hooks live HERE so rarity presentation is authored per-card in data.
class_name CardResource
extends SpellResource

## The three category architectures (Cards_Spells.txt §2). Determines which
## parameter block below the runtime reads, and which effect fires on cast.
enum CardType { ATTACK, DEFENSE, COUNTER }

## Faction identity (Cards_Spells.txt §5): RED = Adrenaline (speed/cast-time),
## BLUE = Control (counters/freeze/trajectory), GREEN = Momentum (mass/heal/
## charging synergy).
enum Faction { RED, BLUE, GREEN }

## Pool rarity (Cards_Spells.txt §5): drives the animation contract above.
enum Rarity { COMMON, UNCOMMON, RARE }

@export_group("Card Identity")

## Which category architecture this card uses.
@export var card_type: CardType = CardType.ATTACK

## Faction the card belongs to (deck building + visual identity).
@export var faction: Faction = Faction.RED

## Pool rarity. COMMON = standard cast visuals; UNCOMMON/RARE unlock the
## bespoke animation hooks below.
@export var rarity: Rarity = Rarity.COMMON

## CASTING COST in tiers (1-3) — the card's hold-to-cast duration AND its
## UI gauge segments (Cards_Spells.txt §6). The card input must be HELD for
## casting_cost x CardCasterComponent.cost_tier_seconds before it fires.
## Unlike the Base Fireball's charge, holding LONGER gives no velocity bonus —
## the cost is the cost. Movement is penalized during the hold (ramp to
## stationary), just like the fireball.
@export_range(1, 3) var casting_cost: int = 1

## TRUE = the card can ONLY be played onto the Stack (during the time-slow
## window after an opponent's card cast) — Counter cards are locked in
## neutral play (Cards_Spells.txt §4). The CardCasterComponent enforces this.
@export var is_reactive_only: bool = false

## Player-facing rules text shown on the HUD card (what it does + damage).
@export_multiline var description: String = ""

@export_group("Card Art")

## 2D card-art face shown in the draft phase and the in-round hand dock.
@export var ui_sprite: Texture2D

## Pixel-art sprite used for the projectile/wall in 3D space (replaces the
## projectile/barrier scene's placeholder art when set).
@export var world_sprite: Texture2D

@export_group("Rarity Animation Hooks (Uncommon/Rare)")

## Bespoke cast-presentation scene instanced at the caster's rig on cast
## (pure visual, frees itself). Empty = the standard generic cast VFX.
@export var cast_vfx_scene: PackedScene

## Named animation on the wizard rig's future AnimationPlayer to play on cast
## (Uncommon "minor bespoke character animations"). Empty = none.
@export var cast_animation_name: StringName = &""

## Camera trauma added when this card fires (Rare: "high-effort,
## screen-shaking"). 0 = the standard small cast bump only.
@export_range(0.0, 1.0) var screen_shake_intensity: float = 0.0

@export_group("Attack (Category A)")
# base_speed / damage / projectile_size / bounciness / projectile_scene are
# inherited from SpellResource — the Base Fireball and ATTACK cards share the
# same ballistic parameter surface.

## Maximum projectile flight time in seconds (Cards_Spells.txt: lifetime)
## before self-destruction. Overrides the projectile scene's default.
@export var lifetime: float = 2.2

## Number of projectiles spawned simultaneously (spread-shot). 1 = single.
@export_range(1, 5) var projectile_count: int = 1

## Lateral X speed (sim units/sec) given to each projectile beyond the first,
## fanning the spread outward symmetrically. Ignored when projectile_count = 1.
@export var spread_x_speed: float = 220.0

## ATTACK cards go ON THE STACK: the spell is staged behind the countdown
## window and fires when MatchController releases the stack — from the
## caster's position AT RELEASE, so the attacker keeps aiming. (Retained as
## data: the rollback sprint converts the wall-clock window to these ticks.)
@export var stage_ticks: int = 15

## HOMING (Creative Director): 0..1 — how hard the projectile curves toward
## and seeks the enemy wizard. 0.2 = a gentle arc across the court; 1.0
## would be a hunter. Cleared when a barrier captures and reflects the ball.
@export_range(0.0, 1.0) var homing_strength: float = 0.0

## BARRIER BREAKER (Creative Director — the Spark Bolt): instead of being
## captured, this projectile SHATTERS the wall (glass burst) and SPLITS
## into two smaller balls that continue through, each dealing 1 damage.
@export var barrier_breaker: bool = false

@export_group("Defense & Utility (Category B)")

## Barrier prefab (an SGStaticBody2D scene — see scenes/barrier.tscn). The
## caster deploys it in front of the wizard; projectiles bounce off it via
## the standard deterministic wall reflection.
@export var barrier_scene: PackedScene

## Physical width and height of the barrier collider, in sim units
## (1 unit = 1 cm). Applied to the barrier's shape at deploy time.
## (204 = the baseline after the Creative Director's -20% then -15% passes.)
@export var wall_size: Vector2 = Vector2(204.0, 40.0)

## Seconds the barrier stays in play before despawning.
## (1.5 = the Creative Director's halved-lifetime pass — walls are a beat,
## not a fortress.)
@export var wall_lifetime: float = 1.5

## Lateral (X-axis) drift speed of the wall, sim units/sec. 0 = static.
@export var wall_movement_speed: float = 0.0

## TRUE = the wall detonates on first impact, disrupting nearby projectile
## physics. (Data field per Cards_Spells.txt; effect lands with later cards.)
@export var is_exploding: bool = false

## Seconds of "Perfect Parry" window for hyper-speed returns off this wall.
## (Data field per Cards_Spells.txt; effect lands with later cards.)
@export var rebound_window: float = 0.0

## TRUE = incoming projectile damage converts to player healing instead.
## (Data field per Cards_Spells.txt; effect lands with later cards.)
@export var healing_absorb: bool = false

## Sim units in front of the caster (down-court) the barrier deploys at.
## (120 — pulled closer so the camera's shoulder yaw doesn't make a
## dead-ahead wall READ as laterally offset; the sim placement is exactly
## the caster's X, proven by test_card_system Phase B.)
@export var wall_offset_y: float = 120.0

@export_subgroup("Window of Affect (Defense)")
# DEFENSE WOA (Creative Director): defense casts are INSTANT; skill lives in
# WHEN you cast. The closer the incoming ball is to hitting you at deploy
# time, the higher the WOA (0..1) — a last-second block charges the ball on
# the wall (anticipation hold + building camera shake, Lethal-Company style)
# then ricochets it back FASTER and at a HARSHER angle.

## Distance (sim units) at which an incoming ball starts counting toward the
## WOA. Ball at this distance = WOA 0; ball touching you = WOA 1.
@export var woa_range: float = 600.0

## Reflect speed multiplier at WOA 1 (a casual early block stays ~1x).
@export var woa_max_reflect: float = 2.5

## Seconds the ball charges ON the wall before releasing, at WOA 1
## (scales down to ~0 for early blocks).
@export var woa_max_hold_seconds: float = 0.6

## Ricochet harshness at WOA 1: lateral speed as a fraction of the reflect
## speed, ON TOP of a 0.3 base every block gets (Creative Director: reflected
## balls should carom off the arena side walls). > 1 = steeper than diagonal.
@export var woa_ricochet: float = 1.2

@export_subgroup("Charging-Synergy Utility")
# Special sub-type (Cards_Spells.txt §2B): castable for FREE without breaking
# an in-progress charge channel. Data fields land now; the dash/draw effects
# arrive with the deck/draft system.

## TRUE = casting this card does NOT break the caster's current charge.
@export var cast_while_charging: bool = false

## Instant X-axis surge distance along the baseline, sim units.
@export var movement_dash_distance: float = 0.0

## Cards drawn instantly on successful execution.
@export var conditional_draw: int = 0

@export_group("Counter (Category C)")
# Counters are REACTIVE ONLY (set is_reactive_only = true): locked in neutral,
# unlocked during the Stack window (Cards_Spells.txt §4).

## Seconds the counter field stays armed after cast (sim-time ticks — during
## the 10% Stack window each sim second stretches to 10 real seconds).
## (Legacy reflect-counter field; the baseline counter is now a projectile.)
@export var opportunity_window: float = 1.0

## Velocity multiplier applied to a redirected projectile (Manifesto: the
## baseline counter returns the ball at 2x speed toward its original caster).
@export var speed_modifier: float = 2.0

@export_subgroup("Window of Affect (Counter)")
# COUNTER WOA (Creative Director): counters cast INSTANTLY during an enemy's
# Stack countdown. The WOA = how far that countdown has run (cast just before
# the enemy spell releases = WOA 1). WOA can scale ANY attribute per card —
# the baseline frost wave scales its slow STRENGTH.

## Seconds the frost slow lasts on the struck wizard (the ice-cube countdown).
@export var slow_duration: float = 3.0

## Movement speed scale applied by the slow at WOA 0 (early, weak counter).
@export var slow_scale_weak: float = 0.6

## Movement speed scale at WOA 1 (last-moment counter — much harsher).
@export var slow_scale_strong: float = 0.3

## Instant X-axis offset to clear a lane on counter cast, sim units.
## (Data field per Cards_Spells.txt; effect lands with later cards.)
@export var teleport_distance: float = 0.0

## Seconds the opponent's movement/tracking freezes on a successful counter.
## (Data field per Cards_Spells.txt; effect lands with later cards.)
@export var freeze_duration: float = 0.0

## Seconds of total i-frame phase immunity granted on cast.
## (Data field per Cards_Spells.txt; effect lands with later cards.)
@export var phase_immunity: float = 0.0
