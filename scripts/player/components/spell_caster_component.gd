## spell_caster_component.gd — Deterministic spell spawner with tick cooldown.
##
## ROLE: Listens for the cast input bit each simulated tick and, when off
## cooldown, instantiates the equipped SpellResource's projectile scene at a
## fixed-point offset in front of the caster, then fires it down-court via the
## projectile's launch() API. Sibling of MovementComponent under
## PlayerController (composition — this component never moves the player and
## MovementComponent never casts).
##
## ALL simulation math here is 64.16 fixed-point (SGFixed, ONE = 65536).
## Float @exports (seconds / sim units per second) are converted ONCE to
## fixed-point per-tick values in _ready() — same tuning model as
## MovementComponent. The per-tick hot path touches integers only.
##
## COOLDOWN (Creative Director requirement): casts are gated by a tick-counted
## cooldown. This prevents input spam and, critically, bounds how many
## projectiles a burst of (possibly mispredicted) inputs can spawn — protecting
## the rollback buffers from entity floods.
##
## ROLLBACK CONTRACT: exposes _network_process(input), _save_state(),
## _load_state(state). The cooldown counter is the component's ONLY mutable sim
## state and it is a plain int of TICKS (never seconds), so saving/loading it
## replays bit-identically on every peer.
##
## NOTE — projectile lifecycle: locally-spawned projectiles are NOT yet
## rollback-managed. When a rollback occurs today, an already-spawned fireball
## is not despawned/respawned. The rollback SyncManager's spawn() will own
## projectile lifecycle in a later sprint; this component's spawn call site is
## where that integration lands.
class_name SpellCasterComponent
extends Node

## Fired immediately after a projectile is spawned and launched, carrying the
## SpellResource that produced it (so listeners can distinguish card spells
## from the baseline default attack — see SpellResource.is_card). UI/SFX/VFX
## hook ONLY — listeners read, they never modify backend or sim data.
signal spell_cast(projectile: Node, spell: SpellResource)

## Fired on the tick a charge begins (cast input held, cooldown elapsed,
## spell has a cast_time). Visual/SFX hook (e.g. CastChargeVFXComponent).
signal cast_charge_started(spell: SpellResource)

## Fired when an in-progress charge fully drains away after the cast input was
## released (see the GRAVEYARD note in _network_process — progress decays, it
## is never zeroed instantly).
signal cast_charge_canceled

## MARIO-KART CHARGE PHASES (Creative Director directive): fired whenever the
## charge crosses a phase boundary. 0 = igniting (below the minimum cast
## time), 1/2/3 = escalating boost phases across the boost window — like
## drift-spark colors. Presentation hook ONLY (CastChargeVFXComponent ramps
## particle color/speed/intensity; MatchController ramps camera rumble); the
## level is DERIVED from _charge_ticks, never stored as extra sim state.
signal cast_charge_level_changed(level: int)

## The spell this caster fires (e.g. res://resources/spells/base_fireball.tres).
## Data-only resource; all per-tick conversions of its stats happen here.
@export var spell: SpellResource

## Total hold time (seconds) at which the charge maxes out: movement reaches
## fully STATIONARY and the release velocity reaches max_speed_multiplier.
## Clamped to at least the spell's cast_time. The movement penalty is a ramp —
## the longer you charge, the slower you move, hitting 0 at this mark
## (Creative Director directive, supersedes the old flat 45% scale).
@export var max_charge_time: float = 1.5

## Release-velocity multiplier at a FULL charge (1.0x at the minimum cast
## time, scaling linearly up to this across the boost window). Capped at 4x
## per the Creative Director; the projectile's own terminal_velocity is the
## final safety ceiling.
@export_range(1.0, 4.0) var max_speed_multiplier: float = 4.0

## AIMED THROWS (Creative Director): the movement input held at release
## tilts the launch — lateral speed up to this fraction of forward speed at
## a full hold (the angle, not the pace). Mobile maps joystick distance here.
@export_range(0.0, 1.0) var aim_max_fraction: float = 0.5

## Ticks of held direction that count as a FULL aim (0.4 s).
@export var aim_full_hold_ticks: int = 24

## Seconds between casts (REQUIRED — Creative Director). Converted once to a
## whole number of ticks: ceil(cooldown_time * tick_rate), minimum 1 tick.
@export var cooldown_time: float = 0.5

## Simulation ticks per second. MUST match the project physics tick rate now,
## and the rollback network tick rate later. Changing this rescales all the
## cached per-tick values (done once in _ready()).
@export var tick_rate: int = 60

## Which way down-court this caster fires on the sim Y axis: +1 or -1.
## -1 = North/down-court toward the opposing wall (sim -Y) — the initialized
## facing, so a frame-0 cast with no prior movement input fires at the wall
## (Creative Director mandate). Player 2 (far baseline) overrides this to +1.
@export var cast_direction_y: int = -1

## Node spawned projectiles are parented under (e.g. an arena-level
## "Projectiles" container). Leave empty to default to the caster body's
## parent — keeps projectiles OUT of the caster's own transform hierarchy.
@export var projectile_container_path: NodePath

## Sim units in front of the caster (along cast_direction_y) to spawn the
## projectile, so the ball never overlaps the caster's own collider on tick 0.
## Tune to: caster collider half-extent + spell.projectile_size + a small gap.
##
## SETTER (Sprint 2 hotfix): re-caches the fixed-point mirror on EVERY write, so
## live-tweaking this export in the Remote Inspector takes effect on the very
## next cast. Previously the float -> fixed conversion happened only once in
## _ready(), which made runtime edits silently do nothing. The conversion cost
## stays out of the per-tick hot path — it runs only when the value changes.
##
## NOTE for tuners: scene overrides win. test_area.tscn overrides this value on
## its Player instance, so edit it THERE (or on the running game's remote tree),
## not on player.tscn / this script default, when play-testing test_area.
@export var spawn_offset_y: float = 48.0:
	set(value):
		spawn_offset_y = value
		_spawn_offset_y_fp = SGFixed.from_float(value)

## Path to the caster's SGCharacterBody2D. Leave empty to use the component's
## direct parent (the recommended scene shape:
## PlayerController (SGCharacterBody2D) -> SpellCasterComponent).
@export var body_path: NodePath

# --- Cached fixed-point / tick values (computed once in _ready()) ---
var _cooldown_ticks: int = 1      # full cooldown duration, whole ticks
var _cast_ticks: int = 0          # spell.cast_time, whole ticks (0 = instant)
var _max_charge_ticks: int = 1    # full charge mark, whole ticks (>= _cast_ticks)
var _speed_per_tick_fp: int = 0   # spell.base_speed, units/tick (fixed-point)
var _spawn_offset_y_fp: int = 0   # spawn_offset_y, fixed-point sim units
var _bounciness_fp: int = 65536   # spell.bounciness, fixed-point (ONE = 1.0)
var _max_mult_fp: int = 262144    # max_speed_multiplier, fixed-point (4.0)

# Authoritative simulation state (whole ticks, ints only — rollback-safe):
# ticks remaining until the next cast is allowed (0 = ready), and the current
# charge progress toward spell.cast_time.
var _ticks_until_ready: int = 0
var _charge_ticks: int = 0

var _body: SGCharacterBody2D
# Sibling MovementComponent (optional): receives the casting speed penalty.
var _movement: MovementComponent


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "SpellCasterComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	for child in _body.get_children():
		if child is MovementComponent:
			_movement = child
			break
	_cache_fixed_point_values()


## Converts the human-friendly float exports (and the equipped spell's float
## stats) to fixed-point / tick values. Called once in _ready(); call again
## manually if you live-tweak cooldown_time / tick_rate or swap `spell` at
## runtime. spawn_offset_y does NOT need this — its setter re-caches on every
## write (Sprint 2 hotfix).
func _cache_fixed_point_values() -> void:
	var safe_tick_rate: int = maxi(1, tick_rate)
	var tick_fp: int = SGFixed.from_int(safe_tick_rate)

	# seconds -> whole ticks (ceil so 0.5 s @ 60 Hz = exactly 30 ticks, and any
	# fraction always rounds AGAINST the caster — never a free faster cooldown).
	_cooldown_ticks = maxi(1, ceili(cooldown_time * float(safe_tick_rate)))

	# Belt-and-braces re-derive: the spawn_offset_y setter normally keeps this
	# cache fresh, but GDScript runs member initializers top-to-bottom, so the
	# setter's write during default-value init is clobbered when the cache var's
	# own `= 0` initializer runs afterwards. This pass makes _ready() state
	# correct regardless of declaration order.
	_spawn_offset_y_fp = SGFixed.from_float(spawn_offset_y)

	_max_mult_fp = SGFixed.from_float(maxf(1.0, max_speed_multiplier))

	if spell != null:
		# units/sec -> units/tick
		_speed_per_tick_fp = SGFixed.div(SGFixed.from_float(spell.base_speed), tick_fp)
		_bounciness_fp = SGFixed.from_float(spell.bounciness)
		# seconds -> whole ticks (ceil: never a faster cast than tuned). 0 = instant.
		_cast_ticks = 0 if spell.cast_time <= 0.0 else maxi(1, ceili(spell.cast_time * float(safe_tick_rate)))

	# Full-charge mark: at least the minimum cast time (a max_charge_time tuned
	# below cast_time degenerates to "instantly maxed at minimum charge").
	_max_charge_ticks = maxi(_cast_ticks, maxi(1, ceili(max_charge_time * float(safe_tick_rate))))


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## Advances the cooldown and the charge by exactly one tick. MARIO-KART
## CHARGE CAST (Creative Director directive): the cast input is HELD to build
## charge — past the minimum cast time it keeps building toward the full-
## charge mark — and the projectile fires on RELEASE. The longer the hold:
##   - the SLOWER the wizard moves (linear ramp from full speed down to fully
##     STATIONARY at the full-charge mark), and
##   - the FASTER the released projectile flies (1x at minimum charge,
##     scaling linearly up to max_speed_multiplier = 4x at full charge).
## Deterministic: same prior state + same input = bit-identical next state
## on every machine (the boost math is pure fixed-point on _charge_ticks).
##
## GRAVEYARD COMPLIANCE: charge progress BELOW the minimum cast time is NEVER
## lost instantly when the cast input breaks (e.g. a touch slipping off the
## screen) — releasing makes the progress DRAIN one tick per tick instead, so
## a brief slip costs only the slip's duration. cast_charge_canceled fires
## when it drains to zero. Releasing AT or PAST the minimum is the throw —
## that release is intentional by definition.
func _network_process(input: Dictionary) -> void:
	if _ticks_until_ready > 0:
		_ticks_until_ready -= 1

	var holding: bool = InputCommand.get_cast(input) == 1
	var level_before: int = _charge_level()
	var charging: bool = false

	if holding and _ticks_until_ready == 0:
		if _cast_ticks <= 0:
			# Instant-cast spell: no charge window at all, no boost.
			_spawn_projectile(SGFixed.ONE)
			_ticks_until_ready = _cooldown_ticks
		else:
			if _charge_ticks == 0:
				cast_charge_started.emit(spell)
			# Build toward the full-charge mark, then sit there (held at max =
			# stationary wizard at 4x release power — maximum risk/reward).
			_charge_ticks = mini(_charge_ticks + 1, _max_charge_ticks)
			charging = true
	elif _charge_ticks > 0:
		if _charge_ticks >= _cast_ticks:
			# RELEASE-FIRE: the charge cleared the minimum cast time, so this
			# release IS the throw. Boost scales with the banked charge, and the
			# fired GAUGE (1/2/3) sizes the projectile (captured BEFORE the reset).
			var multiplier_fp: int = _velocity_multiplier_fp()
			var fired_level: int = _charge_level()
			_charge_ticks = 0
			_spawn_projectile(multiplier_fp, fired_level)
			_ticks_until_ready = _cooldown_ticks
		else:
			# Released below the minimum: drain, never hard-reset (GRAVEYARD).
			# No movement penalty while draining.
			_charge_ticks -= 1
			if _charge_ticks == 0:
				cast_charge_canceled.emit()

	# Phase-boundary presentation hook (drift-spark levels). Derived state —
	# re-fires harmlessly during rollback re-simulation, like all VFX signals.
	var level_after: int = _charge_level()
	if level_after != level_before:
		cast_charge_level_changed.emit(level_after)

	# While charging, push this tick's ramped movement penalty for the body's
	# NEXT tick (min-composes with other casters; the accumulator self-resets,
	# so an idle caster pushes nothing — see MovementComponent).
	if charging and _movement != null:
		_movement.apply_speed_penalty(_movement_scale_fp())


## Charge phase for presentation (0 = igniting below minimum cast time,
## 1/2/3 = boost phases). Pure function of _charge_ticks — no stored state.
func _charge_level() -> int:
	if _cast_ticks <= 0 or _charge_ticks < _cast_ticks:
		return 0
	var boost_range: int = _max_charge_ticks - _cast_ticks
	if boost_range <= 0:
		return 3
	var progress: int = _charge_ticks - _cast_ticks
	if progress >= boost_range:
		return 3
	if progress * 2 >= boost_range:
		return 2
	return 1


## PRESENTATION getter (HUD only — never read by sim): how far the current
## hold has charged toward the full-charge mark, 0.0..1.0. Floats are fine here
## because nothing deterministic consumes this — the on-screen fireball button
## draws a charge ring from it. Returns 0 when not charging.
func charge_fraction() -> float:
	if _max_charge_ticks <= 0:
		return 0.0
	return clampf(float(_charge_ticks) / float(_max_charge_ticks), 0.0, 1.0)


## Current charge GAUGE for the HUD (0 = igniting below the throwable minimum,
## 1/2/3 = the three boost gauges). Public mirror of _charge_level() so the
## segmented cast-button ring can light a third per gauge.
func charge_level() -> int:
	return _charge_level()


## Projectile SIZE multiplier per charge gauge (Creative Director): gauge 1 =
## base size, gauge 2 = +15%, gauge 3 = +35%. Index = charge level (0-3); level
## 0 never fires so its 1.0 is academic.
const CHARGE_SIZE_MULTIPLIERS: Array[float] = [1.0, 1.0, 1.15, 1.35]


## Release-velocity multiplier for the CURRENT charge, fixed-point. 1x at the
## minimum cast time, scaling linearly to _max_mult_fp (4x) at the full-charge
## mark. Pure fixed-point int math.
func _velocity_multiplier_fp() -> int:
	var boost_range: int = _max_charge_ticks - _cast_ticks
	if boost_range <= 0:
		return _max_mult_fp
	var progress: int = clampi(_charge_ticks - _cast_ticks, 0, boost_range)
	var fraction_fp: int = SGFixed.div(SGFixed.from_int(progress), SGFixed.from_int(boost_range))
	return SGFixed.ONE + SGFixed.mul(fraction_fp, _max_mult_fp - SGFixed.ONE)


## Movement speed scale for the CURRENT charge, fixed-point: linear ramp from
## ONE (no charge) down to 0 (fully stationary) at the full-charge mark.
func _movement_scale_fp() -> int:
	var fraction_fp: int = SGFixed.div(
			SGFixed.from_int(_charge_ticks),
			SGFixed.from_int(maxi(1, _max_charge_ticks)))
	return maxi(0, SGFixed.ONE - fraction_fp)


## Snapshot of all mutable simulation state. Ints only — required for rollback
## hashing and serialization. (Spawned projectiles are NOT captured here yet —
## see the lifecycle NOTE in the header.)
func _save_state() -> Dictionary:
	return {
		"cd": _ticks_until_ready,
		"ch": _charge_ticks,
	}


## Restores a snapshot produced by _save_state().
func _load_state(state: Dictionary) -> void:
	_ticks_until_ready = int(state.get("cd", 0))
	_charge_ticks = int(state.get("ch", 0))


## Clean slate for a new round (called by PlayerController.reset_for_round).
func reset_cast_state() -> void:
	_ticks_until_ready = 0
	if _charge_ticks > 0:
		_charge_ticks = 0
		cast_charge_canceled.emit()


# =====================================================================
# Internals
# =====================================================================

## Instantiates the spell's projectile scene at the caster's fixed-point
## position offset down-court, syncs it into the SG physics engine, and
## launches it. Pure int math from caster position to launch velocity.
##
## GLOBAL SPACE END TO END (Sprint 2 hotfix round 2): the caster body and the
## projectile container are DIFFERENT nodes with potentially different origins
## (e.g. the body under a translated SGFixedNode2D wrapper, projectiles under
## an arena-level "Projectiles" container). Reading the body's LOCAL
## fixed_position and writing it into the projectile's LOCAL fixed_position
## silently mixed those two spaces — a body whose wrapper held the translation
## read as local (0,0) and the fireball spawned at the container's origin
## (midfield). Both ends now use the ClassDB-verified SGFixedNode2D global API:
## get_global_fixed_position() / set_global_fixed_position() (deterministic
## fixed-point parent-transform walk inside the GDExtension — still int math).
func _spawn_projectile(velocity_multiplier_fp: int = SGFixed.ONE, charge_level: int = 1) -> void:
	if spell == null:
		push_warning("SpellCasterComponent: no SpellResource assigned — cast ignored.")
		return
	if spell.projectile_scene == null:
		push_warning("SpellCasterComponent: spell '%s' has no projectile_scene assigned — cast ignored." % spell.display_name)
		return

	# SIZE BY CHARGE GAUGE (Creative Director): gauge 1 = base, 2 = +10%, 3 = +25%.
	# The charged radius feeds BOTH the spawn-bounds clamp (so a bigger bolt still
	# stays in the lane) and apply_size below.
	var size_mult: float = CHARGE_SIZE_MULTIPLIERS[clampi(charge_level, 0, 3)]
	var radius_units: float = spell.projectile_size * size_mult

	# Spawn ORIGIN in GLOBAL fixed-point space (int math only), clamped so the
	# ball's full radius stays inside the lane — no projectile spawns outside the
	# map. Aim (below) tilts the launch VELOCITY only, never the spawn position, so
	# the throw is still fully aimable.
	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(radius_units), _arena_bound_fp())
	var spawn_y: int = caster_pos.y + _spawn_offset_y_fp * cast_direction_y

	# STACK WINNER REWARD: consume the one-shot launch-speed boost. This MUTATES
	# the caster's sim state, so it must run HERE (the caster's deterministic tick),
	# NOT in the projectile's _network_spawn — on a rollback this tick re-runs and
	# re-consumes identically.
	var winner_boost_fp: int = SGFixed.ONE
	if _body.has_method(&"consume_speed_boost"):
		winner_boost_fp = _body.consume_speed_boost()
	var speed_fp: int = SGFixed.mul(SGFixed.mul(_speed_per_tick_fp, velocity_multiplier_fp), winner_boost_fp)

	# ROLLBACK SPAWN (Sprint 22): hand a deterministic, rewindable payload (int /
	# fixed-point only; the hit-source as its stable scene path) to SyncManager.
	# spawn(). FireballController._network_spawn() does the positioning, arming, and
	# launch — identical in single-player (spawn just instantiates + inits) and
	# under rollback (the spawn is registered and re-created identically per re-sim).
	var data := {
		"px": spawn_x, "py": spawn_y,
		"vx": _aim_vx_fp(speed_fp), "vy": speed_fp * cast_direction_y, "b": _bounciness_fp,
		"mask": PhysicsLayers.projectile_mask_for(cast_direction_y),
		"dmg": spell.damage,
		"shat": 1 if charge_level >= 3 else 0,
		"size": SGFixed.from_float(radius_units),
		"src": str(_body.get_path()),
	}
	var projectile: Node = SyncManager.spawn("Fireball", _resolve_container(), spell.projectile_scene, data)

	# Presentation hook (camera trauma / SFX via MatchController). Suppress on a
	# rollback re-sim so a corrected tick doesn't re-fire the feedback.
	if projectile != null and (SyncManager == null or not SyncManager.is_in_rollback()):
		spell_cast.emit(projectile, spell)


## Lateral launch component from the held movement input: dir x forward
## speed x aim_max_fraction x (held ticks / full ticks, capped at 1).
func _aim_vx_fp(forward_speed_fp: int) -> int:
	if _movement == null or aim_full_hold_ticks <= 0:
		return 0
	var ticks: int = mini(_movement.get_aim_ticks(), aim_full_hold_ticks)
	if ticks <= 0 or _movement.get_aim_dir() == 0:
		return 0
	var fraction_fp: int = SGFixed.div(SGFixed.from_int(ticks), SGFixed.from_int(aim_full_hold_ticks))
	var max_vx_fp: int = SGFixed.mul(forward_speed_fp, SGFixed.from_float(clampf(aim_max_fraction, 0.0, 1.0)))
	return _movement.get_aim_dir() * SGFixed.mul(max_vx_fp, fraction_fp)


## The lane half-width (fixed-point) spawns clamp to — read from our sibling
## MovementComponent so it tracks the same scene-overridden bound the body uses.
func _arena_bound_fp() -> int:
	if _movement != null:
		return _movement.arena_half_width_fp()
	return SGFixed.from_float(400.0)


func _resolve_container() -> Node:
	if not projectile_container_path.is_empty():
		var container: Node = get_node_or_null(projectile_container_path)
		if container != null:
			return container
		push_warning("SpellCasterComponent: projectile_container_path not found — falling back to the caster body's parent.")
	return _body.get_parent()


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
