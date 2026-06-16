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

## HIT POP (Sprint 23 batch 2, Creative Director): on a hit the rig SQUASH/STRETCHES — a decaying
## cosine pop (squash in, spring through a stretch, settle). Runs on the WALL clock so it snaps at
## full speed inside slow-mo / a hitstop freeze (it's impact feedback, not motion). Layered on top
## of the existing red flash + spark burst. hit_pop_amount = peak squash fraction.
@export var hit_pop_seconds: float = 0.32
@export var hit_pop_amount: float = 0.24
@export var hit_pop_frequency: float = 30.0

## CHARACTER FRAME PIPELINE (Sprint 24) — static "key pose" textures swapped on the Sprite3D's
## palette_swap.gdshader material_override, layered UNDER all the procedural motion above.
## PRESENTATION ONLY: no sim/rollback state, exactly like the rest of this component.
##
## This wizard's active SKIN (the recolour) + the BASE skin (the reference palette the art was
## drawn in = the shader's match source). blue / red / future shop skins. Leave null to render
## the art un-recoloured (the shader falls back to identity passthrough).
@export var skin: SkinPalette
@export var base_skin: SkinPalette
## Container scanned for the close_call near-miss read (the arena's hostile projectiles).
@export var projectile_container_path: NodePath = ^"../../Projectiles"
## Wizard body half-width in SIM units (the close_call HIT boundary; 52.5 = default collider).
@export var body_half_width: float = 52.5
## Sim units OUTSIDE the hit boundary that still count as a "barely missed" close call.
@export var close_call_margin: float = 80.0
## Seconds a momentary pose (cast / hurt / close_call) holds before falling back to motion poses.
@export var pose_hold_seconds: float = 0.25
## Visual speed (m/s) above which the running pose shows.
@export var run_pose_speed: float = 0.6
## True if the art is drawn FACING RIGHT (flip_h then mirrors it when moving left). Flip if not.
@export var face_art_default_right: bool = true

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
var _flash_color: Color = Color(1.0, 0.5, 0.42)   # element tint (Elements.flash_color) of the current flash
var _wall_last_msec: int = 0
# HIT POP (Sprint 23 batch 2): wall-clock start of the squash/stretch impact pop (0 = none), and the
# HealthComponent it reads the struck element from to tint the flash.
var _hit_pop_msec: int = 0
var _health: Node = null
# DEATH state (visual only).
var _dead: bool = false
var _death_vel: Vector3 = Vector3.ZERO
var _death_off: Vector3 = Vector3.ZERO
var _death_t: float = 0.0

# --- FRAME PIPELINE state (presentation only; never saved, never sim) ---
var _material: ShaderMaterial = null   # the Sprite3D's palette_swap material_override (or null)
var _body: Node = null                 # the SGCharacterBody2D parent (close_call scan)
var _container: Node = null            # the projectile container (close_call scan)
var _cur_tex: Texture2D = null         # the pose texture currently on the sprite
var _uploaded_tex: Texture2D = null    # last texture pushed to the shader's pose_tex uniform
var _cast_pose: StringName = &"cast_fire"
var _cast_until_msec: int = 0
var _hurt_until_msec: int = 0
var _close_call_until_msec: int = 0
var _ball_prev_dy: Dictionary = {}     # projectile instance_id -> last dy (sim fixed int)
var _body_half_x_fp: int = 0
var _close_margin_fp: int = 0
# Directional facing (front = toward camera, back = away). Static per wizard per perspective:
# cast_direction_y picks the down-court side; view_flip_z is the online mirror.
var _facing: StringName = &"front"
var _cast_dir: int = -1                 # this wizard's down-court sign (from a sibling caster)
var _bridge: VisualBridgeComponent = null
var _skin_folder: String = ""           # premium-skin override folder ("" = base art)


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

	_health = get_node_or_null(health_path)
	if _health != null:
		_health.damaged.connect(_on_damaged)
		_health.knocked_out.connect(_on_knocked_out)
		_health.health_changed.connect(_on_health_changed)

	for sibling in get_parent().get_children():
		if sibling is SpellCasterComponent or sibling is CardCasterComponent:
			sibling.cast_charge_started.connect(_on_charge_started)
			sibling.cast_charge_canceled.connect(_on_charge_ended)
			sibling.spell_cast.connect(_on_cast_released)
			sibling.cast_charge_level_changed.connect(_on_charge_level)
			_cast_dir = sibling.cast_direction_y  # down-court sign -> front/back facing
		elif sibling is MovementComponent:
			# FROST FLASH (Sprint 23 batch 2): a frost wave deals 0 damage, so it never reaches the
			# damage path — flash ICE-blue + pop off the movement slow instead (being frozen IS its hit).
			sibling.slow_started.connect(_on_slowed)
		elif sibling is VisualBridgeComponent:
			_bridge = sibling  # read view_flip_z (the online perspective mirror) for facing

	# --- FRAME PIPELINE wiring (presentation only) ---
	_body = get_parent()
	_container = get_node_or_null(projectile_container_path)
	if _sprite != null:
		# Duplicate the material_override so EACH wizard owns its ShaderMaterial. opponent.tscn
		# INSTANCES player.tscn, so without this both wizards share one material and would fight
		# over pose_tex + the palette (both showing the same pose / same colour).
		var mat: Material = _sprite.get(&"material_override") as Material
		if mat is ShaderMaterial:
			_material = (mat as ShaderMaterial).duplicate() as ShaderMaterial
			_sprite.set(&"material_override", _material)
	_body_half_x_fp = SGFixed.from_float(maxf(0.0, body_half_width))
	_close_margin_fp = SGFixed.from_float(maxf(0.0, close_call_margin))
	_skin_folder = skin.texture_folder_override if skin != null else ""
	_apply_skin()
	_apply_pose(&"idle")


func _process(delta: float) -> void:
	if _rig == null:
		return
	var now: int = Time.get_ticks_msec()
	var wall_dt: float = clampf(float(now - _wall_last_msec) / 1000.0, 0.0, 0.05)
	_wall_last_msec = now

	# DEATH fling overrides all normal animation (the wizard is knocked off). It
	# runs on the SCALED delta (not the wall clock) so the knockout plays in the
	# death slow-mo with the rest of the 3D world (Sprint 20 — the kill must read
	# as a dramatic, visible beat, not a wall-clock blur).
	if _dead:
		_update_death(delta)
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
	# HIT POP (Sprint 23 batch 2): a squash/stretch on impact — a decaying cosine on the WALL clock so
	# it snaps at full speed inside slow-mo / a hitstop freeze. At impact (wave = +1) the rig SQUASHES
	# (shorter + wider); it springs through a stretch and settles as the cosine decays.
	var pop_sx: float = 0.0
	var pop_sy: float = 0.0
	if _hit_pop_msec > 0:
		var pe: float = float(now - _hit_pop_msec) / 1000.0
		if pe < hit_pop_seconds:
			var decay: float = 1.0 - pe / hit_pop_seconds
			var wave: float = cos(pe * hit_pop_frequency) * decay * decay
			pop_sy = -hit_pop_amount * wave
			pop_sx = hit_pop_amount * 0.6 * wave
		else:
			_hit_pop_msec = 0
	var s: float = 1.0 - crouch + pulse + _recoil * 0.08 + pop_sy
	_rig.scale = Vector3(1.0 + crouch * 0.6 - pulse * 0.5 + pop_sx, s, 1.0)

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
			_sprite.set(&"modulate", Color(_flash_color.r, _flash_color.g, _flash_color.b, 1.0 if on_frame else 0.25))
		elif _flicker_until_msec != 0:
			_flicker_until_msec = 0
			_sprite.set(&"modulate", Color.WHITE)
	if wall_dt > 0.0:
		pass  # (wall_dt reserved for future wall-clock blends)

	# --- FRAME PIPELINE (Sprint 24, presentation only): facing + close-call + key-pose ---
	_scan_close_call(now)
	# FRONT/BACK (Sprint 24b): the wizard faces its opponent down-court. Its facing points AWAY
	# from the camera (BACK) on the near side, TOWARD it (FRONT) on the far side. cast_direction_y
	# is the down-court sign; view_flip_z is the online perspective mirror (so each peer sees its
	# OWN wizard's back + the foe's front). flip_h (below) still mirrors L/R on top.
	var flip_z: bool = _bridge != null and _bridge.view_flip_z
	_facing = &"front" if (_cast_dir * (-1 if flip_z else 1)) > 0 else &"back"
	if _sprite != null:
		if dir != 0:
			_sprite.set(&"flip_h", (dir < 0) if face_art_default_right else (dir > 0))
		_apply_pose(_select_pose_name(now, speed))


func _on_damaged(_amount: int) -> void:
	# PRESENTATION ONLY — suppress on rollback re-sims. The damaged signal re-fires every
	# time this tick is re-simulated (the HitDetection _has_hit latch is rolled back + re-set),
	# so without this guard the squash-pop + flicker re-stamp from t=0 on each re-sim. The hit
	# first plays on the forward (predicted) tick where is_in_rollback() is false.
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	var now: int = Time.get_ticks_msec()
	_flicker_until_msec = now + int(flicker_seconds * 1000.0)
	_hit_pop_msec = now
	_hurt_until_msec = now + int(pose_hold_seconds * 1000.0)  # show the hurt key-pose
	# Flash + pop in the STRIKING element's colour (Sprint 23 batch 2): fire = orange, spark = yellow.
	var elem: int = _health.get_last_hit_element() if (_health != null and _health.has_method(&"get_last_hit_element")) else Elements.FIRE
	_flash_color = Elements.flash_color(elem)


## FROZEN (a frost wave's 0-damage "hit"): flash ICE-blue + a squash pop so getting chilled reads as
## an impact too. The damage path never sees the wave (0 damage); this slow is its feedback hook.
func _on_slowed(_duration_ticks: int) -> void:
	# PRESENTATION ONLY — suppress on rollback re-sims (slow_started re-fires per re-sim,
	# same as the damage path above).
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	var now: int = Time.get_ticks_msec()
	_flicker_until_msec = now + int(flicker_seconds * 1000.0)
	_hit_pop_msec = now
	_hurt_until_msec = now + int(pose_hold_seconds * 1000.0)  # show the hurt key-pose (frost)
	_flash_color = Elements.flash_color(Elements.ICE)


## LETHAL hit: fling the wizard BACKWARD off its own baseline edge (the side of
## the court it stands on) on a gravity arc. Pure visual — the sim is already
## parked by the round flow. Reset on the next round when health refills.
func _on_knocked_out() -> void:
	# PRESENTATION ONLY — suppress on rollback re-sims so the twin death-explosion bursts
	# aren't re-spawned when a rollback crosses the KO tick (knocked_out re-fires on re-sim,
	# and a rollback that restores health clears _dead, re-opening the duplicate path). The
	# fling + burst play on the forward tick where is_in_rollback() is false.
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	if _dead or _sprite == null:
		return
	_dead = true
	_apply_pose(&"hurt")  # hold the hurt key-pose through the death fling (_process early-returns)
	_death_t = 0.0
	_death_off = Vector3.ZERO
	var back: float = signf(_rig.global_position.z) if _rig != null else 1.0
	if back == 0.0:
		back = 1.0
	_death_vel = Vector3(0.0, death_up_speed, back * death_back_speed)
	if _rig != null:
		# A bigger, wider EXPLOSION on death (Sprint 20, Creative Director): a dense
		# fiery blast carrying the knockback direction, plus a near-radial white
		# flash. The CPUParticles3D run on scaled time, so the blast slows with the
		# death slow-mo like the rest of the 3D.
		var burst_pos: Vector3 = _rig.global_position + Vector3(0.0, 1.0, 0.0)
		BurstFX.spawn(_rig.get_parent(), burst_pos, Vector3(0.0, 0.5, back),
				Color(1.0, 0.5, 0.25, 0.95), 80, 9.5, 0.14, 100.0)
		BurstFX.spawn(_rig.get_parent(), burst_pos, Vector3.UP,
				Color(1.0, 0.92, 0.7, 0.95), 46, 6.5, 0.11, 175.0)
	Sfx.play(&"hit_wizard")


## Advances the death fling: gravity arc on the sprite's local offset, a flat-
## spin (scale.x flip — the Y-billboard ignores node rotation), shrink + fade.
func _update_death(dt: float) -> void:
	if _sprite == null:
		return
	_death_vel.y -= death_gravity * dt
	_death_off += _death_vel * dt
	_sprite.position = _sprite_base_pos + _death_off
	_death_t += dt
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
		_hit_pop_msec = 0
		_hurt_until_msec = 0
		_cast_until_msec = 0
		_close_call_until_msec = 0
		_ball_prev_dy.clear()
		_sprite.position = _sprite_base_pos
		_sprite.scale = Vector3.ONE
		_sprite.set(&"modulate", Color.WHITE)
		_apply_pose(&"idle")


func _on_charge_started(_spell: Resource) -> void:
	_charging = true
	_charge_level = 0


func _on_charge_level(level: int) -> void:
	_charge_level = level


func _on_charge_ended() -> void:
	_charging = false
	_charge_level = 0


func _on_cast_released(_projectile: Node, spell: Resource) -> void:
	_charging = false
	_charge_level = 0
	_recoil = 1.0
	# CAST KEY-POSE by element: fireball/attack -> cast_fire, counter -> cast_ice, defense ->
	# cast_shield. The emitting signal is already rollback-guarded at the caster, so this only
	# fires on the forward tick.
	_cast_pose = _cast_pose_for(spell)
	_cast_until_msec = Time.get_ticks_msec() + int(pose_hold_seconds * 1000.0)


# =====================================================================
# FRAME PIPELINE (Sprint 24) — PRESENTATION ONLY (no sim / no saved state)
# =====================================================================

## Upload this wizard's skin to the palette_swap material: src = base palette (what the art
## was drawn in), dst = the active skin's recolour. sRGB values — the shader matches in sRGB.
## color_count 0 = identity passthrough (no skin assigned -> art renders as drawn).
func _apply_skin() -> void:
	if _material == null:
		return
	var base: SkinPalette = base_skin if base_skin != null else skin
	if base == null or skin == null or base.colors.is_empty():
		_material.set_shader_parameter(&"color_count", 0)
		return
	var n: int = mini(skin.colors.size(), base.colors.size())
	var src := PackedVector3Array()
	var dst := PackedVector3Array()
	for i in n:
		var s: Color = base.colors[i]
		var d: Color = skin.colors[i]
		src.append(Vector3(s.r, s.g, s.b))
		dst.append(Vector3(d.r, d.g, d.b))
	_material.set_shader_parameter(&"color_count", n)
	_material.set_shader_parameter(&"src_colors", src)
	_material.set_shader_parameter(&"dst_colors", dst)


## Swap this wizard's skin at RUNTIME (wardrobe / shop preview): re-upload the palette, switch the
## premium-folder source, and force the next frame to re-fetch the pose from the new source.
func set_skin(new_skin: SkinPalette) -> void:
	skin = new_skin
	_skin_folder = new_skin.texture_folder_override if new_skin != null else ""
	_apply_skin()
	_cur_tex = null
	_uploaded_tex = null


## Swap the Sprite3D to a pose texture for the CURRENT facing + skin folder (and feed the shader).
## get_pose applies the front<->back<->idle fallback; with NO art at all the .tscn placeholder
## texture stays put. Keeps the shader's pose_tex synced to whatever texture is actually shown.
func _apply_pose(pose: StringName) -> void:
	if _sprite == null:
		return
	var tex: Texture2D = WizardPoseLibrary.get_pose(pose, _facing, _skin_folder)
	if tex != null and tex != _cur_tex:
		_sprite.set(&"texture", tex)
		_cur_tex = tex
	var shown: Texture2D = _sprite.get(&"texture") as Texture2D
	if _material != null and shown != _uploaded_tex:
		_material.set_shader_parameter(&"pose_tex", shown)
		_uploaded_tex = shown


## The current pose name by priority. hurt > close_call > cast > charging > running > idle.
func _select_pose_name(now: int, speed: float) -> StringName:
	if now < _hurt_until_msec:
		return &"hurt"
	if now < _close_call_until_msec:
		return &"close_call"
	if now < _cast_until_msec:
		return _cast_pose
	if _charging:
		return &"charging"
	if speed > run_pose_speed:
		return &"running"
	return &"idle"


## Map a cast to its key-pose. DEFENSE -> shield; otherwise by the spell/card element.
func _cast_pose_for(spell: Object) -> StringName:
	if spell is CardResource:
		if spell.card_type == CardResource.CardType.DEFENSE:
			return &"cast_shield"
		return _elem_pose(int(spell.element))
	if spell != null:
		var e: Variant = spell.get(&"element")
		if e != null:
			return _elem_pose(int(e))
	return &"cast_fire"


func _elem_pose(element: int) -> StringName:
	match element:
		Elements.ICE:
			return &"cast_ice"
		Elements.SPARK:
			# Optional dedicated spark pose if the artist drops one in; else the fire cast.
			return &"cast_spark" if WizardPoseLibrary.has_pose(&"cast_spark") else &"cast_fire"
		_:
			return &"cast_fire"


## CLOSE CALL — a hostile ball that passes JUST OUTSIDE the hitbox (within close_call_margin)
## but never connects triggers the close_call pose. ROLLBACK-SAFE BY CONSTRUCTION: this runs at
## render rate in _process (which does NOT execute during a rollback re-sim), reads sim positions
## WITHOUT ever writing sim/saved state, and the pose sits BELOW hurt in priority — so a rollback
## cannot double-fire it, and a near-miss that re-sims into a real hit shows hurt instead. The
## explicit is_in_rollback() guard is belt-and-braces (the recently-shipped animator-hook idiom).
func _scan_close_call(now: int) -> void:
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	if _body == null or _container == null or not is_instance_valid(_container):
		return
	if not _body.has_method(&"get_global_fixed_position"):
		return
	var my: SGFixedVector2 = _body.get_global_fixed_position()
	var alive: Dictionary = {}
	for child in _container.get_children():
		if not child.has_method(&"get_velocity_y") or not child.has_method(&"get_hit_source"):
			continue
		if child.get_hit_source() == _body:
			continue  # our own throw
		var id: int = child.get_instance_id()
		alive[id] = true
		var bp: SGFixedVector2 = child.get_global_fixed_position()
		var dy: int = my.y - bp.y
		var prev: Variant = _ball_prev_dy.get(id)
		_ball_prev_dy[id] = dy
		if prev == null:
			continue
		if (int(prev) > 0) == (dy > 0):
			continue  # hasn't crossed our baseline this frame
		# Crossed our depth line — was it a BARELY-missed pass on X (outside the hitbox, but close)?
		var dx: int = absi(my.x - bp.x)
		var ext: SGFixedVector2 = child.get_collider_half_extents() if child.has_method(&"get_collider_half_extents") else SGFixed.vector2(0, 0)
		var inner: int = _body_half_x_fp + ext.x          # the hit boundary
		var outer: int = inner + _close_margin_fp
		if dx > inner and dx <= outer:
			_close_call_until_msec = now + int(pose_hold_seconds * 1000.0)
	# Prune departed projectiles so the dictionary can't grow unbounded.
	for id in _ball_prev_dy.keys():
		if not alive.has(id):
			_ball_prev_dy.erase(id)
