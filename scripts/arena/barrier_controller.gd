## barrier_controller.gd — Deployable card barrier (Defense, Category B).
##
## ROLE: a temporary wall a DEFENSE card deploys in front of its caster.
## It lives on the WALLS collision layer, so projectiles (mask = walls only)
## reflect off it through the exact same deterministic move_and_collide +
## bounce() path as the arena walls — zero new collision code. (That cuts
## both ways: your OWN throws bounce off your wall too — don't fire through
## your own bulwark.)
##
## WINDOW OF AFFECT (Creative Director, round-system sprint): defense casts
## are INSTANT; the skill is timing. The caster measures the WOA at deploy
## (how close the incoming ball already was) and arms this barrier with it.
## The FIRST hostile ball that reaches the wall is CAPTURED: it sticks to
## the wall and charges for hold_ticks (camera shake builds — the
## Lethal-Company anticipation beat), then releases back down-court at
## reflect_mult x its captured speed, ricocheting sideways harder the higher
## the WOA (deterministic angle — the "random" sign is a parity hash of the
## capture position, identical on every peer). Later balls just bounce
## normally off the static body.
##
## All sim math is 64.16 fixed-point ints. Sim state: age, position, capture
## hold counter + latched release parameters. Spawn/despawn lifecycle is
## local for now — the rollback SyncManager owns it in a later sprint (the
## captured-ball NODE REFERENCE is part of that same lifecycle debt).
##
## DEPLOY CONTRACT: CardCasterComponent instantiates the scene, positions it
## via set_global_fixed_position + sync_to_physics_engine, then calls
## deploy() with the card's wall parameters and arm_window_of_affect() with
## the measured WOA (fixed-point/tick values — the caster converts the
## CardResource floats once at cast time).
class_name BarrierController
extends SGStaticBody2D

## Emitted when the barrier's lifetime expires (it frees itself afterwards).
signal barrier_expired

## A hostile ball stuck to the wall and is charging (anticipation hold). [param intensity]
## (0..1 = the WOA blended with the incoming speed) scales the presentation for the whole beat:
## ripple size/speed, slow-mo depth, rumble, and the release slam (MatchController reads it). [param
## reflects] = how many times THIS ball has already been reflected (SHIELD-REFLECT RALLY): MatchController
## scales the shake up per reflect (reflect_shake_growth) so a rally's shake builds exchange by exchange.
signal capture_started(intensity: float, reflects: int)

## Per held tick: progress 0..1 toward release. Camera-shake hook
## (MatchController ramps rumble off this — pure presentation).
signal capture_charging(progress: float)

## The held ball released (reflected). MatchController slams the camera.
signal capture_released

## When false, the local tick driver idles (rollback SyncManager later).
@export var local_tick_driver_enabled: bool = true

## VARIABLE ANTICIPATION HOLD (Sprint 23, Creative Director): the captured ball waits on the
## wall for a hold scaled by the reflect INTENSITY (= WOA blended with incoming speed) — a low
## intensity (slow ball / loose timing) gives a short pause, a high intensity (fast ball / a
## last-moment block) the full dramatic hold. Ticks @ 60 Hz: 8 = 0.13 s, 36 = 0.6 s (then
## stretched by the shield slow-mo). The same intensity scales the ripple + slow-mo + rumble + slam.
@export var capture_hold_min_ticks: int = 8
@export var capture_hold_max_ticks: int = 36
## Incoming speed (sim units/tick) that counts as a FULL-intensity fast ball — the captured
## |velocity| is normalised against this (clamped 0..1) for the speed half of the intensity blend.
@export var capture_ref_speed: float = 35.0
## Fraction of the intensity that comes from SPEED (the rest from the WOA block-timing). 0.5 = even.
@export_range(0.0, 1.0) var capture_speed_weight: float = 0.5

## SHIELD-REFLECT RALLY (Creative Director): each successive reflect of the SAME ball in a rally
## stretches the anticipation hold by reflect_hold_growth (the rumble auto-slows to suit — it is
## progress-driven, so a longer hold = a slower build) and the released ball accelerates in lockstep
## (the mover's rally cap, ProjectileMovementComponent.rally_speed_growth). reflect 0 — the FIRST block
## — is the baseline (no growth), so a single block keeps its current feel; escalation builds from the
## rally's second exchange on. Bounded by max_rally_reflects (shared ceiling with the mover).
@export var reflect_hold_growth: float = 1.35
@export var max_rally_reflects: int = 6

## Visual rig (a Node3D holding the wall mesh). The barrier positions it from
## the sim ONCE at deploy (and per tick when drifting) — barriers have no
## VisualBridge because they have no movement component to signal from.
@export var visual_root_path: NodePath = NodePath("Visual")

## sim units -> meters (must match VisualBridgeComponent's scale).
@export var sim_to_world_scale: float = 0.01

## Visual wall height in meters (sim is 2D — height is presentation only).
@export var visual_height: float = 1.2

# --- Deploy-time parameters (fixed-point/ticks, set by deploy()) ---
var _lifespan_ticks: int = 0      # 0 = until despawn by round flow
var _move_speed_fp: int = 0       # X drift per tick (Category B movement_speed)
var _half_w_fp: int = 0
var _half_h_fp: int = 0

# --- Window of Affect (set by arm_window_of_affect()) ---
var _owner_body: Node = null      # the deploying wizard (its balls don't count)
var _woa_fp: int = 0              # 0..ONE, measured at deploy
var _hold_ticks: int = 0          # anticipation hold length
var _reflect_mult_fp: int = 65536 # release speed multiplier
var _ricochet_fp: int = 0         # lateral fraction of release speed
var _release_dir: int = -1        # vy sign of the RELEASED ball (back down-court)
var _release_mask: int = 0        # collision mask for the released ball (0 = keep)
var _woa_armed: bool = false      # one capture per barrier

# Authoritative sim state.
var _age_ticks: int = 0
var _capture_remaining: int = 0   # > 0 = a ball is held, charging
var _captured_speed_fp: int = 0   # |velocity| at capture
var _capture_total: int = 0       # effective hold length (charge-progress denominator; saved as "ct")
var _captured_ball: Node = null   # node ref (rollback lifecycle debt, see header)

var _visual_root: Node3D

## NETPLAY visual mirror (client perspective): true on the CLIENT so the barrier's
## VISUAL Z is mirrored, exactly like VisualBridgeComponent does for wizards/projectiles.
## The barrier has NO VisualBridge (it positions its own mesh in _sync_visual), so without
## this its sprite rendered on the WRONG side on the client (P2's wall appeared on P1's side)
## while the hitbox sat correctly — the recurring client-perspective class. Sim untouched.
var _view_flip_z: bool = false

## SHIELD-REFLECT RALLY: reflect_hold_growth as fixed-point (cached in _ready).
var _hold_growth_fp: int = SGFixed.ONE


func _ready() -> void:
	# HARDCODED COLLISION LAYERS (graveyard rule: the editor fails to persist
	# SG layer assignments). The barrier IS a wall: projectiles bounce off it;
	# it scans nothing itself.
	collision_layer = PhysicsLayers.LAYER_WALLS
	collision_mask = 0
	fixed_rotation = 0
	_visual_root = get_node_or_null(visual_root_path) as Node3D
	_hold_growth_fp = SGFixed.from_float(maxf(1.0, reflect_hold_growth))

	# Mirror the visual on the CLIENT (same rule as VisualBridgeComponent): the client
	# presents the court spun front-to-back so ITS wizard is at the near baseline.
	var nm: Node = get_node_or_null(^"/root/NetworkManager")
	if nm != null and nm.netplay and not multiplayer.is_server():
		_view_flip_z = true

	# ROLLBACK (Sprint 22 Phase 2b): a barrier is spawned mid-match via SyncManager.spawn,
	# so under a live netplay match the rollback SyncManager drives it (via "network_sync")
	# and the local _physics_process driver must idle. Single-player keeps self-driving.
	if SyncManager != null and SyncManager.started:
		local_tick_driver_enabled = false
		add_to_group(&"network_sync")


## Arms the barrier. Called by CardCasterComponent AFTER positioning the body.
##  - half_w_fp / half_h_fp: collider half-extents, fixed-point sim units
##    (CardResource.wall_size / 2).
##  - lifespan_ticks: whole ticks before despawn (ceil of wall_lifetime).
##  - move_speed_fp: X drift, fixed-point sim units per TICK (0 = static).
func deploy(half_w_fp: int, half_h_fp: int, lifespan_ticks: int, move_speed_fp: int = 0) -> void:
	_half_w_fp = half_w_fp
	_half_h_fp = half_h_fp
	_lifespan_ticks = lifespan_ticks
	_move_speed_fp = move_speed_fp
	_age_ticks = 0

	# Resize the collider to the card's wall_size. The scene's shape resource
	# is DUPLICATED first: instanced scenes share sub-resources, so mutating
	# the shared shape would silently resize every other live barrier.
	var shape_node: SGCollisionShape2D = null
	for child in get_children():
		if child is SGCollisionShape2D:
			shape_node = child
			break
	if shape_node != null and shape_node.shape != null:
		var shape: SGShape2D = shape_node.shape.duplicate()
		shape.set(&"extents_x", half_w_fp)
		shape.set(&"extents_y", half_h_fp)
		shape_node.shape = shape
	sync_to_physics_engine()

	_sync_visual()


## Arms the Window of Affect (called right after deploy()).
##  - owner_body: the deploying wizard (its own throws are ignored).
##  - hostile_dir: vy SIGN of incoming hostile balls; the release reverses it.
##  - woa_fp: 0..ONE block quality measured at deploy.
##  - hold_ticks / reflect_mult_fp / ricochet_fp: precomputed by the caster
##    from the CardResource's WOA tuning.
##  - release_mask: collision mask stamped onto the released ball — it now
##    belongs to the OWNER's side, so it must pass the owner's one-way walls
##    and collide with the enemy's (PhysicsLayers.projectile_mask_for).
func arm_window_of_affect(owner_body: Node, hostile_dir: int, woa_fp: int,
		hold_ticks: int, reflect_mult_fp: int, ricochet_fp: int,
		release_mask: int = 0) -> void:
	_owner_body = owner_body
	_release_dir = -hostile_dir
	_woa_fp = woa_fp
	_hold_ticks = maxi(0, hold_ticks)
	_reflect_mult_fp = reflect_mult_fp
	_ricochet_fp = ricochet_fp
	_release_mask = release_mask
	_woa_armed = true


## ROLLBACK SPAWN (Sprint 22 Phase 2b): the deterministic, rewindable initializer —
## called by SyncManager.spawn() on the spawn tick AND re-run identically on every
## rollback re-spawn, so it is PURE SETUP from an int/path-only payload. Does what
## CardCasterComponent._resolve_defense used to do inline: position + one-way layer +
## deploy + arm the Window of Affect (owner wizard resolved by its stable scene path).
func _network_spawn(data: Dictionary) -> void:
	set_global_fixed_position(SGFixed.vector2(int(data.get("px", 0)), int(data.get("py", 0))))
	if data.has("layer"):
		collision_layer = int(data["layer"])  # one-way side layer, set BEFORE the sync
	sync_to_physics_engine()
	deploy(int(data.get("hw", 0)), int(data.get("hh", 0)), int(data.get("life", 0)), int(data.get("move", 0)))
	var owner_path: String = String(data.get("owner", ""))
	var owner: Node = get_node_or_null(NodePath(owner_path)) if owner_path != "" else null
	arm_window_of_affect(owner, int(data.get("hdir", -1)), int(data.get("woa", 0)),
			int(data.get("hold", 0)), int(data.get("refl", SGFixed.ONE)),
			int(data.get("ric", 0)), int(data.get("rmask", 0)))


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## One tick: capture/hold/release first, optional X drift, then lifetime.
func _network_process(_input: Dictionary) -> void:
	# DESPAWN-WINDOW GUARD (netplay): skip a tick while detached (despawn retire window, or a
	# wall-clock round-reset clear landing mid-tick) — get_parent() / sync_to_physics_engine
	# on a treeless body crash otherwise. Mirrors FireballController._network_process.
	if not is_inside_tree():
		return
	if _capture_remaining > 0:
		_tick_capture()
	elif _woa_armed:
		_try_capture()

	if _move_speed_fp != 0:
		var pos: SGFixedVector2 = fixed_position
		pos.x += _move_speed_fp
		fixed_position = pos
		sync_to_physics_engine()
		_sync_visual()

	_age_ticks += 1
	if _lifespan_ticks > 0 and _age_ticks >= _lifespan_ticks:
		# A still-held ball is released (weakly) rather than orphaned frozen.
		if _capture_remaining > 0:
			_capture_remaining = 1
			_tick_capture()
		barrier_expired.emit()
		# Rewindable free: SyncManager.despawn under a live match, else queue_free.
		# Idempotent if expiry re-fires before the free lands.
		_despawn()


## Scan for the FIRST hostile ball touching the wall face and capture it:
## freeze it in place (launch 0,0 — also restarts its lifespan) and start
## the anticipation hold. Pure fixed-point int proximity test.
func _try_capture() -> void:
	var container: Node = get_parent()
	if container == null:
		return
	for child in container.get_children():
		if child == self or not child.has_method(&"redirect") or not child.has_method(&"get_hit_source"):
			continue
		if child.get_hit_source() == _owner_body:
			continue  # the owner's own throw: plain physics bounce only
		if not _in_capture_band(child):
			continue
		# BARRIER BREAKER (Spark Bolt): no capture — the wall SHATTERS and
		# the bolt splits into two 1-damage shards that continue through.
		if "splits_on_barrier" in child and child.splits_on_barrier:
			child.split_on_barrier(-_release_dir)
			_shatter()
			return
		# CAPTURE: bank its speed, then freeze it on the wall.
		var vel: SGFixedVector2 = SGFixed.vector2(child.get_velocity_x(), child.get_velocity_y())
		_captured_speed_fp = vel.length()
		_captured_ball = child
		# REFLECT INTENSITY (0..ONE, deterministic): blend the WOA (block timing — a tighter /
		# last-moment block reads higher) with the incoming speed (faster reads higher). Drives the
		# variable sim hold here AND the presentation (emitted on capture_started). Fixed-point int.
		var intensity_fp: int = _reflect_intensity_fp()
		var span: int = maxi(0, capture_hold_max_ticks - capture_hold_min_ticks)
		var base_hold: int = maxi(1, capture_hold_min_ticks + (span * intensity_fp) / SGFixed.ONE)
		# SHIELD-REFLECT RALLY: stretch the hold 1.2x per PRIOR reflect of this ball (reflect 0 = the
		# baseline first block). The rumble is progress-driven (capture_charging = 1 - remaining/total),
		# so a longer total auto-SLOWS the anticipation build to fill it — no separate pulse-speed code.
		var reflects: int = _captured_ball.get_reflect_count() if _captured_ball.has_method(&"get_reflect_count") else 0
		_capture_total = maxi(1, (base_hold * _rally_pow_fp(_hold_growth_fp, mini(reflects, max_rally_reflects))) >> 16)
		_capture_remaining = _capture_total
		_woa_armed = false  # one capture per barrier
		_freeze_owner()  # Task 3: lock the deploying wizard from the capture tick (re-pushed each hold tick)
		child.launch(0, 0, SGFixed.ONE)
		# INTERCEPT FX (pure visual): shield-colored shards FLATTEN against
		# the wall — fanning UP/ACROSS the wall plane like a snowball hitting
		# a wall, not toward the target (Creative Director).
		if _visual_root != null:
			BurstFX.spawn(get_parent(), _visual_root.global_position + Vector3(0, 0.2, 0),
					Vector3.UP, Color(0.45, 0.9, 0.6, 0.95), 30, 3.6, 0.07, 80.0)
		Sfx.play(&"shield_capture")
		capture_started.emit(float(intensity_fp) / float(SGFixed.ONE), reflects)
		return


## Reflect INTENSITY in fixed-point 0..ONE: a deterministic blend of the WOA (0..ONE block
## quality) and the incoming speed normalised against capture_ref_speed; capture_speed_weight
## splits the two. Used for the variable hold + the presentation scale — both inputs are sim state.
func _reflect_intensity_fp() -> int:
	var ref_fp: int = SGFixed.from_float(maxf(1.0, capture_ref_speed))
	var speed_norm_fp: int = clampi(SGFixed.div(_captured_speed_fp, ref_fp), 0, SGFixed.ONE)
	var w_fp: int = SGFixed.from_float(clampf(capture_speed_weight, 0.0, 1.0))
	var spd_part: int = SGFixed.mul(speed_norm_fp, w_fp)
	var woa_part: int = SGFixed.mul(clampi(_woa_fp, 0, SGFixed.ONE), SGFixed.ONE - w_fp)
	return clampi(spd_part + woa_part, 0, SGFixed.ONE)


## SHIELD-CAPTURE MOTION LOCK (Task 3): pin the deploying wizard in place for as long as this barrier
## grips a captured ball. Re-pushed EVERY held tick (short TTL) so the lock tracks the hold exactly and
## lapses ~1 tick after release. Deterministic sim write — same owner, same tick on every peer — and the
## owner's MovementComponent saves the freeze ("fz"), so a rollback across the hold restores it.
func _freeze_owner() -> void:
	if _owner_body != null and is_instance_valid(_owner_body) and _owner_body.has_method(&"freeze_movement"):
		_owner_body.freeze_movement(2)


## SHIELD-REFLECT RALLY: deterministic fixed-point power base_fp^exp (exp >= 0) for the hold
## escalation — a small bounded loop (exp <= max_rally_reflects) of SGFixed.mul, identical on peers.
func _rally_pow_fp(base_fp: int, exp: int) -> int:
	var result: int = SGFixed.ONE
	for _i in maxi(0, exp):
		result = SGFixed.mul(result, base_fp)
	return result


## SHIELD-REFLECT RALLY: a wizard's CardCasterComponent (its shield/card runtime) — direct child path
## first, then a class scan (deterministic scene-tree order). Used to re-enable the receiver's shield.
func _find_card_caster(wizard: Node) -> Node:
	if wizard == null:
		return null
	var direct: Node = wizard.get_node_or_null(^"CardCasterComponent")
	if direct != null:
		return direct
	for child in wizard.get_children():
		if child is CardCasterComponent:
			return child
	return null


## AABB capture-band test (shared by _try_capture and would_capture): is [param ball] overlapping this
## wall face, ball-size- AND speed-aware (the BALL's own half-extents + its per-tick Y step widen the
## band, so a wide frost wave or a fast ball can't slip the scan). Pure fixed-point int — deterministic.
func _in_capture_band(ball: Node) -> bool:
	var my_pos: SGFixedVector2 = get_global_fixed_position()
	var ball_pos: SGFixedVector2 = ball.get_global_fixed_position()
	var band_x: int = _half_w_fp + SGFixed.from_float(28.0)
	var band_y: int = _half_h_fp + SGFixed.from_float(34.0)
	var ext: SGFixedVector2 = ball.get_collider_half_extents() if ball.has_method(&"get_collider_half_extents") else SGFixed.vector2(0, 0)
	var dyn_band_y: int = band_y + ext.y + (absi(ball.get_velocity_y()) if ball.has_method(&"get_velocity_y") else 0)
	return absi(my_pos.x - ball_pos.x) < band_x + ext.x and absi(my_pos.y - ball_pos.y) < dyn_band_y


## The wizard this barrier defends (its own throws pass through). Read by a ball's hit detection to tell
## whether THIS barrier protects the wizard the ball is about to strike.
func get_owner_body() -> Node:
	return _owner_body


## LAST-MOMENT BLOCK FIX: true when this barrier is currently holding [param ball], OR is armed and the
## ball is within its capture band — i.e. the barrier is intercepting that ball FOR its owner. The ball's
## hit detection reads this so a ball caught at the last instant doesn't ALSO land its hit on the owner
## ("I blocked but still took damage"). Barrier-breakers (Spark Bolt) SHATTER instead of being captured,
## so they are NOT intercepted — they still deal their hit (matches "it won't happen with sparks").
func would_capture(ball: Node) -> bool:
	if ball == null or not is_instance_valid(ball):
		return false
	if _captured_ball == ball:
		return true  # already held on the wall
	if not _woa_armed:
		return false
	if "splits_on_barrier" in ball and ball.splits_on_barrier:
		return false
	if ball.has_method(&"get_hit_source") and ball.get_hit_source() == _owner_body:
		return false  # the owner's own throw is never captured
	return _in_capture_band(ball)


## GLASS SHATTER (a barrier breaker got through): shard burst flattened
## against the wall plane + the glass crack, then the wall is gone.
func _shatter() -> void:
	if _visual_root != null:
		BurstFX.spawn(get_parent(), _visual_root.global_position + Vector3(0, 0.4, 0),
				Vector3.UP, Color(0.85, 1.0, 0.92, 0.95), 38, 4.5, 0.055, 85.0)
	Sfx.play(&"shield_shatter")
	_despawn()


## One held tick: charge toward release; at zero, fling the ball back at
## reflect_mult x speed with the WOA ricochet angle.
func _tick_capture() -> void:
	if _captured_ball == null or not is_instance_valid(_captured_ball):
		_capture_remaining = 0
		return
	_capture_remaining -= 1
	if _capture_remaining > 0:
		# The held ball is frozen at velocity 0 ON PURPOSE — keep the stuck-projectile
		# cleanup (ProjectileMovementComponent's stall despawn) from reclaiming it mid-hold.
		if _captured_ball.has_method(&"keep_alive"):
			_captured_ball.keep_alive()
		_freeze_owner()  # Task 3: keep the deploying wizard locked for the whole hold
		var total: float = float(maxi(1, _capture_total))
		capture_charging.emit(1.0 - float(_capture_remaining) / total)
		return

	# RELEASE. Deterministic "random" ricochet sign: parity hash of the
	# captured ball's fixed X (bit 16 = the 1-sim-unit bit).
	var ball_pos: SGFixedVector2 = _captured_ball.get_global_fixed_position()
	var sign_hash: int = 1 if ((ball_pos.x >> 16) & 1) == 1 else -1
	# SHIELD-REFLECT RALLY: each reflect sends the ball back faster — the mover's rally multiplier
	# (1.2^reflect_count, bounded) on TOP of the WOA reflect_mult. The mover's matching escalating
	# speed cap (rally_speed_mult_fp) keeps the higher speed from clipping back to the base ceiling.
	var rally_mult_fp: int = _captured_ball.rally_speed_mult_fp() if _captured_ball.has_method(&"rally_speed_mult_fp") else SGFixed.ONE
	var speed_out_fp: int = SGFixed.mul(SGFixed.mul(_captured_speed_fp, _reflect_mult_fp), rally_mult_fp)
	var vx: int = SGFixed.mul(speed_out_fp, _ricochet_fp) * sign_hash
	var vy: int = speed_out_fp * _release_dir

	# A REFLECTED FROST WAVE (Icey Retort) must RELIABLY return and freeze its
	# thrower (Creative Director: "the reflected ice wall must ALWAYS freeze").
	# The court-wide wall used to inherit the random ricochet veer and miss; now it
	# flies STRAIGHT back (no lateral kick) and gently HOMES onto the original
	# thrower (captured BEFORE we overwrite the hit source), so it can't drift
	# off-angle past a thrower who stepped aside. Pure fixed-point, deterministic.
	var is_frost: bool = "slow_ticks" in _captured_ball and _captured_ball.slow_ticks > 0
	var original_thrower: Node = null
	if _captured_ball.has_method(&"get_hit_source"):
		original_thrower = _captured_ball.get_hit_source()
	if is_frost:
		vx = 0

	if _captured_ball.has_method(&"set_hit_source"):
		_captured_ball.set_hit_source(_owner_body)
	if _release_mask != 0:
		_captured_ball.collision_mask = _release_mask  # now the OWNER's ball
	if _captured_ball.has_method(&"set_homing"):
		if is_frost and original_thrower != null:
			# Gentle tracking onto the thrower — reliable, not an instant lock.
			_captured_ball.set_homing(original_thrower, SGFixed.from_float(0.4))
		else:
			_captured_ball.set_homing(null, 0)  # a reflected ball flies true
	# SHIELD-REFLECT RALLY: re-enable the RECEIVER's shield so they can re-block and keep the rally
	# alive (the ball now flies back toward original_thrower). Deterministic — this release is a sim
	# tick, so both peers re-enable together; sparks shatter and never reach here, as intended.
	if original_thrower != null and is_instance_valid(original_thrower):
		var rcaster: Node = _find_card_caster(original_thrower)
		if rcaster != null and rcaster.has_method(&"make_defense_available"):
			rcaster.make_defense_available()
	# Record this reflect on the ball (grows its hold + speed escalation for the NEXT exchange).
	if _captured_ball.has_method(&"add_reflect"):
		_captured_ball.add_reflect()
	_captured_ball.launch(vx, vy, SGFixed.ONE)
	_captured_ball = null
	capture_released.emit()


func _save_state() -> Dictionary:
	var pos: SGFixedVector2 = fixed_position
	return {
		"age": _age_ticks,
		"px": pos.x,
		"py": pos.y,
		"cap": _capture_remaining,
		"ct": _capture_total,
		"cs": _captured_speed_fp,
		"wa": 1 if _woa_armed else 0,
	}


func _load_state(state: Dictionary) -> void:
	_age_ticks = int(state.get("age", 0))
	_capture_remaining = int(state.get("cap", 0))
	_capture_total = int(state.get("ct", 0))
	_captured_speed_fp = int(state.get("cs", 0))
	_woa_armed = int(state.get("wa", 0)) == 1
	var pos: SGFixedVector2 = fixed_position
	pos.x = int(state.get("px", pos.x))
	pos.y = int(state.get("py", pos.y))
	fixed_position = pos
	sync_to_physics_engine()
	_sync_visual()


## Rewindable free (mirrors FireballController): SyncManager.despawn under a live match,
## else queue_free. Routed through here so the despawn itself rolls back.
func _despawn() -> void:
	if SyncManager != null and SyncManager.started and has_meta("spawn_name"):
		SyncManager.despawn(self)
	else:
		queue_free()


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in a later sprint.
func _physics_process(_delta: float) -> void:
	if local_tick_driver_enabled:
		_network_process({})


# =====================================================================
# Internals
# =====================================================================

## Places and sizes the 3D wall mesh from the sim state. Presentation only —
## floats are fine here (the ONLY fixed->float conversion in this script).
func _sync_visual() -> void:
	if _visual_root == null:
		return
	var pos: SGFixedVector2 = get_global_fixed_position()
	# fixed (64.16) -> sim units -> meters.
	var x_m: float = (pos.x / 65536.0) * sim_to_world_scale
	var z_m: float = (pos.y / 65536.0) * sim_to_world_scale
	# CLIENT view mirror (presentation only — same as VisualBridgeComponent): flip Z so
	# the barrier renders on its OWNER's side from the client's spun-around perspective.
	if _view_flip_z:
		z_m = -z_m
	_visual_root.global_position = Vector3(x_m, visual_height * 0.5, z_m)
	_visual_root.scale = Vector3(
			maxf(0.05, (_half_w_fp / 65536.0) * 2.0 * sim_to_world_scale),
			visual_height,
			maxf(0.05, (_half_h_fp / 65536.0) * 2.0 * sim_to_world_scale))
