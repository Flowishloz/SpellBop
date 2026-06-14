## wizard_animator_component.gd — Procedural placeholder animations.
##
## PURE VISUAL: reads the rig's float transform and caster/health signals,
## writes ONLY rig Y/roll/scale and sprite modulate — never sim state, and
## never the rig X/Z (those belong to the VisualBridge).
##
## BASIC ANIMATION SET (Creative Director) — all procedural until sprite
## sheets land:
##   RUNNING L/R — locomotion bob (Y bounce) + a lean INTO the travel
##                 direction; the lean's sign is the left/right read.
##   TURNING     — a direction flip kicks extra lean velocity through the
##                 spring: a whippy counter-tilt that settles (follow-through).
##   CHARGING    — anticipation crouch + a pulse that quickens per charge
##                 level (driven by both casters' charge signals).
##   CASTING     — recoil kick on release (rig pops back, spring settles).
##   TAKING DAMAGE — the sprite FLICKERS (alpha strobe + red flash) on the
##                 wall clock so hits read instantly even inside slow-mo.
##
## Locomotion uses the SCALED frame delta so animation slows with the world
## in the Stack window (the wizard exists in the 3D space); the damage
## flicker alone runs on the wall clock (it's feedback, not motion).
class_name WizardAnimatorComponent
extends Node

@export var rig_path: NodePath = NodePath("../WizardRig")
@export var sprite_path: NodePath = NodePath("../WizardRig/Sprite3D")
@export var dust_path: NodePath = NodePath("../WizardRig/DustParticles")
@export var health_path: NodePath = NodePath("../Health")

## Lean angle per m/s of travel (radians), and its clamp.
@export var lean_per_speed: float = 0.10
@export var max_lean: float = 0.22

## Locomotion bob.
@export var bob_frequency: float = 9.0
@export var bob_height: float = 0.07

## Damage flicker.
@export var flicker_seconds: float = 0.5
@export var flicker_hz: float = 9.0

## DEATH ANIMATION (Phase 4): on a LETHAL hit the wizard is flung BACKWARD off
## its own baseline edge — a visual physics arc on the SPRITE (the sim is parked
## on KO; the VisualBridge owns rig X/Z, so the death fling lives on the sprite's
## local offset). Reset when the round restarts (health refills).
@export var death_back_speed: float = 4.6    # m/s backward, off the edge
@export var death_up_speed: float = 3.3      # m/s upward kick
@export var death_gravity: float = 9.5       # m/s^2 fall
@export var death_spin_speed: float = 9.0    # flat-spin rate (scale.x flip)

var _rig: Node3D
var _sprite: Node3D
var _sprite_base_pos: Vector3 = Vector3.ZERO  # the sprite's authored local offset
var _dust: Node
var _prev_x: float = 0.0
var _has_prev: bool = false
var _bob_phase: float = 0.0
var _lean: float = 0.0
var _lean_vel: float = 0.0
var _prev_dir: int = 0
var _charging: bool = false
var _charge_level: int = 0
var _recoil: float = 0.0
var _flicker_until_msec: int = 0
var _wall_last_msec: int = 0
# DEATH state (visual only).
var _dead: bool = false
var _death_vel: Vector3 = Vector3.ZERO
var _death_off: Vector3 = Vector3.ZERO
var _death_t: float = 0.0


func _ready() -> void:
	_rig = get_node_or_null(rig_path) as Node3D
	_sprite = get_node_or_null(sprite_path) as Node3D
	if _sprite != null:
		_sprite_base_pos = _sprite.position  # capture the authored Y offset (feet on floor)
	_dust = get_node_or_null(dust_path)
	_wall_last_msec = Time.get_ticks_msec()
	if _rig == null:
		push_warning("WizardAnimatorComponent: rig not found — animator inert.")
		return

	var health: Node = get_node_or_null(health_path)
	if health != null:
		health.damaged.connect(_on_damaged)
		health.knocked_out.connect(_on_knocked_out)
		health.health_changed.connect(_on_health_changed)

	for sibling in get_parent().get_children():
		if sibling is SpellCasterComponent or sibling is CardCasterComponent:
			sibling.cast_charge_started.connect(_on_charge_started)
			sibling.cast_charge_canceled.connect(_on_charge_ended)
			sibling.spell_cast.connect(_on_cast_released)
			sibling.cast_charge_level_changed.connect(_on_charge_level)


func _process(delta: float) -> void:
	if _rig == null:
		return
	var now: int = Time.get_ticks_msec()
	var wall_dt: float = clampf(float(now - _wall_last_msec) / 1000.0, 0.0, 0.05)
	_wall_last_msec = now

	# DEATH fling overrides all normal animation (the wizard is knocked off).
	if _dead:
		_update_death(wall_dt)
		return

	# --- locomotion read (visual X only — never sim) -------------------
	var x: float = _rig.position.x
	var vx: float = 0.0
	if _has_prev and delta > 0.0:
		vx = (x - _prev_x) / delta
	_prev_x = x
	_has_prev = true
	var speed: float = absf(vx)
	var dir: int = 0 if speed < 0.3 else (1 if vx > 0.0 else -1)

	# TURNING: a sign flip whips extra lean velocity through the spring.
	if dir != 0 and _prev_dir != 0 and dir != _prev_dir:
		_lean_vel += float(dir) * 2.4
	if dir != 0:
		_prev_dir = dir

	# RUNNING lean (into the direction of travel), spring-settled.
	var lean_target: float = clampf(-vx * lean_per_speed, -max_lean, max_lean)
	_lean_vel += (lean_target - _lean) * 90.0 * delta
	_lean_vel *= maxf(0.0, 1.0 - 10.0 * delta)
	_lean += _lean_vel * delta

	# RUNNING bob (zeroes out when idle).
	var speed_norm: float = clampf(speed / 6.0, 0.0, 1.0)
	_bob_phase += delta * bob_frequency * (0.4 + speed_norm)
	var bob: float = absf(sin(_bob_phase)) * bob_height * speed_norm

	# CHARGING crouch + pulse (quickens with the charge level).
	var crouch: float = 0.0
	var pulse: float = 0.0
	if _charging:
		crouch = 0.05
		pulse = sin(_bob_phase * (2.0 + float(_charge_level) * 1.5)) * 0.025 * (1.0 + float(_charge_level) * 0.5)

	# CAST recoil decays through its own spring-ish falloff.
	_recoil = maxf(0.0, _recoil - 4.0 * delta)

	_rig.position.y = bob
	_rig.rotation.z = _lean
	var s: float = 1.0 - crouch + pulse + _recoil * 0.08
	_rig.scale = Vector3(1.0 + crouch * 0.6 - pulse * 0.5, s, 1.0)

	# CHARGE SHAKE (Creative Director): the wizard rattles harder as each fireball
	# gauge banks. Pure visual jitter on the SPRITE within the rig (rig X/Z belong
	# to the VisualBridge). Wall-clock phase so it reads at full speed in slow-mo.
	if _sprite != null:
		if _charging and _charge_level > 0:
			var amp: float = 0.013 * float(_charge_level)
			var ct: float = float(now) / 1000.0 * (26.0 + 14.0 * float(_charge_level))
			# Jitter AROUND the authored base offset — never reset to (0,0,0), or
			# the sprite's Y offset is lost and the wizard sinks into the floor.
			_sprite.position = _sprite_base_pos + Vector3(sin(ct * 1.7) * amp, sin(ct * 2.6 + 1.1) * amp, 0.0)
		elif _sprite.position != _sprite_base_pos:
			_sprite.position = _sprite_base_pos

	# Dust trail while running (minimal squash partner).
	if _dust != null:
		_dust.set(&"emitting", speed_norm > 0.25)

	# --- DAMAGE flicker (wall clock — reads instantly in slow-mo) ------
	if _sprite != null:
		if now < _flicker_until_msec:
			var phase: float = float(now) / 1000.0 * flicker_hz
			var on_frame: bool = fmod(phase, 1.0) < 0.5
			_sprite.set(&"modulate", Color(1.0, 0.45, 0.45, 1.0 if on_frame else 0.25))
		elif _flicker_until_msec != 0:
			_flicker_until_msec = 0
			_sprite.set(&"modulate", Color.WHITE)
	if wall_dt > 0.0:
		pass  # (wall_dt reserved for future wall-clock blends)


func _on_damaged(_amount: int) -> void:
	_flicker_until_msec = Time.get_ticks_msec() + int(flicker_seconds * 1000.0)


## LETHAL hit: fling the wizard BACKWARD off its own baseline edge (the side of
## the court it stands on) on a gravity arc. Pure visual — the sim is already
## parked by the round flow. Reset on the next round when health refills.
func _on_knocked_out() -> void:
	if _dead or _sprite == null:
		return
	_dead = true
	_death_t = 0.0
	_death_off = Vector3.ZERO
	var back: float = signf(_rig.global_position.z) if _rig != null else 1.0
	if back == 0.0:
		back = 1.0
	_death_vel = Vector3(0.0, death_up_speed, back * death_back_speed)
	if _rig != null:
		BurstFX.spawn(_rig.get_parent(), _rig.global_position + Vector3(0.0, 1.0, 0.0),
				Vector3(0.0, 0.5, back), Color(1.0, 0.5, 0.3, 0.95), 32, 5.5)
	Sfx.play(&"hit_wizard")


## Advances the death fling: gravity arc on the sprite's local offset, a flat-
## spin (scale.x flip — the Y-billboard ignores node rotation), shrink + fade.
func _update_death(wall_dt: float) -> void:
	if _sprite == null:
		return
	_death_vel.y -= death_gravity * wall_dt
	_death_off += _death_vel * wall_dt
	_sprite.position = _sprite_base_pos + _death_off
	_death_t += wall_dt
	var spin: float = sin(_death_t * death_spin_speed)
	var shrink: float = clampf(1.0 - _death_t * 0.32, 0.18, 1.0)
	_sprite.scale = Vector3(spin * shrink, shrink, shrink)
	var a: float = clampf(1.0 - _death_t * 0.5, 0.0, 1.0)
	_sprite.set(&"modulate", Color(1.0, 0.55, 0.5, a))


## Round restart (health refilled): clear the death state and restore the sprite.
func _on_health_changed(current: int, _max_health: int) -> void:
	if _dead and current > 0:
		_dead = false
		_death_t = 0.0
		_death_off = Vector3.ZERO
		_sprite.position = _sprite_base_pos
		_sprite.scale = Vector3.ONE
		_sprite.set(&"modulate", Color.WHITE)


func _on_charge_started(_spell: Resource) -> void:
	_charging = true
	_charge_level = 0


func _on_charge_level(level: int) -> void:
	_charge_level = level


func _on_charge_ended() -> void:
	_charging = false
	_charge_level = 0


func _on_cast_released(_projectile: Node, _spell: Resource) -> void:
	_charging = false
	_charge_level = 0
	_recoil = 1.0
