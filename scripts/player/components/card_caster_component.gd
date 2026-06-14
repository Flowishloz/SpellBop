## card_caster_component.gd — Deterministic card hand: 3 slots, THE STACK.
##
## ROLE: the runtime half of the card framework (CardResource is the data
## half). Holds a 3-slot test hand (keys 8/9/0 → input card bit) and resolves
## the three category architectures (Creative Director, stack-rework sprint):
##
##   ATTACK  — COMMITS ON PRESS (Creative Director: no charge/channel time). The
##             instant the slot is pressed the spell is STAGED — it sits ON THE
##             STACK (spell_staged; MatchController opens the countdown window,
##             the StackDisplay shows the card to BOTH players) while the caster
##             moves freely to aim. The projectile fires only when
##             MatchController calls release_staged() as the countdown expires —
##             so the on-screen timer and the release are the same event.
##   DEFENSE — INSTANT on key press (never on the stack). Skill = timing:
##             the Window of Affect is measured at deploy (BarrierController).
##             One-way: the owner's own projectiles pass through it.
##   COUNTER — press during an enemy countdown SLAPS the counter ONTO THE
##             STACK: it stages like an attack (overlapping card on the
##             display) and MatchController RESETS the window timer — a new
##             spell is on the stack. Its WOA (how late into the previous
##             countdown it was slapped) is LATCHED at that moment. When the
##             window finally expires the stack resolves LIFO: the counter's
##             frost wave fires first, then the attack releases.
##
## COOLDOWNS: per-slot, 4 s (placeholder until the deck system makes cards
## limited-use). A slot's cooldown starts when its card is STAGED/deployed.
##
## ROLLBACK CONTRACT: _network_process(input) / _save_state() / _load_state().
## Sim state is plain ints: per-slot cooldowns, the staged queue + latched WOAs,
## and the previous raw slot (press-edge derivation). NETPLAY NOTES: the
## reactive lock, the counter WOA and the release call ride the wall-clock
## Stack window — those flagged sites convert to tick math with rollback.
class_name CardCasterComponent
extends Node

## Same shape as SpellCasterComponent.spell_cast — fired when an effect
## actually resolves (projectile fired / barrier deployed / wave loosed).
signal spell_cast(projectile: Node, spell: SpellResource)

## A card was STAGED onto the stack (an attack pressed, or a counter slapped on
## during a window). MatchController opens/RESETS the countdown window and
## queues this caster for LIFO release; the StackDisplay shows it.
signal spell_staged(card: CardResource)

## Card-specific post-fire hook (rarity presentation: screen shake, bespoke
## cast VFX scene). Fired alongside spell_cast at resolution.
signal card_cast(card: CardResource)

## VESTIGIAL (kept for the shared caster interface): cards no longer charge, so
## this caster never emits these — but CastChargeVFXComponent / WizardAnimator /
## CardHandHUD auto-connect to BOTH caster types, so the declarations must stay
## or those connect() calls fail. Only SpellCasterComponent's fireball drives
## charge VFX now.
signal cast_charge_started(spell: SpellResource)
signal cast_charge_canceled
signal cast_charge_level_changed(level: int)

## A card press was refused (reactive-only outside the Stack window, or the
## slot is on cooldown with a fresh press). UI hook — once per press.
signal card_rejected(card: CardResource)

## The 3-slot test hand (Creative Director: keys 8 / 9 / 0). The draft/deck
## system will write these slots at round start in a later sprint.
@export var card_slot_1: CardResource
@export var card_slot_2: CardResource
@export var card_slot_3: CardResource

## PER-SLOT seconds between uses of the SAME card (Creative Director: 4 s —
## a placeholder economy until cards become limited-use via the deck system).
@export var cooldown_time: float = 4.0

## Simulation ticks per second (must match the project tick rate).
@export var tick_rate: int = 60

## Down-court direction for this caster's projectiles / barrier placement:
## -1 = toward the far wall (P1), +1 = P2's override.
@export var cast_direction_y: int = -1

## Container spawned projectiles AND barriers are parented under.
@export var projectile_container_path: NodePath

## Sim units in front of the caster to spawn attack projectiles.
@export var spawn_offset_y: float = 70.0

## AIMED THROWS (same model as SpellCasterComponent): the direction held at
## stage RELEASE tilts the bolt, scaled by how long it was held.
@export_range(0.0, 1.0) var aim_max_fraction: float = 0.5
@export var aim_full_hold_ticks: int = 24

## Path to the caster's SGCharacterBody2D. Empty = direct parent.
@export var body_path: NodePath

# --- Cached fixed-point / tick values (computed once in _ready()) ---
var _cooldown_ticks: int = 1
var _spawn_offset_y_fp: int = 0

# Authoritative simulation state (ints only — rollback-safe).
var _slot_cd: Array[int] = [0, 0, 0]  # per-slot cooldown ticks remaining
# THE STACK accepts MULTIPLE spells per caster (Creative Director): a staged
# QUEUE, oldest first (max 3 — the per-slot cooldown, which starts at the
# stage, prevents the same card appearing twice). release_staged() pops the
# NEWEST, so MatchController's per-entry calls preserve global LIFO.
var _staged_queue: Array[int] = []
var _staged_woas: Array[int] = []
var _prev_raw_slot: int = 0         # last tick's card input (press-edge derivation)

# Presentation edge-tracking (NOT sim state — rejection is a UI event).
var _rejected_slot_latch: int = 0

var _body: SGCharacterBody2D
var _movement: MovementComponent


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "CardCasterComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	for child in _body.get_children():
		if child is MovementComponent:
			_movement = child
			break
	_cache_fixed_point_values()


func _cache_fixed_point_values() -> void:
	var safe_tick_rate: int = maxi(1, tick_rate)
	_cooldown_ticks = maxi(1, ceili(cooldown_time * float(safe_tick_rate)))
	_spawn_offset_y_fp = SGFixed.from_float(spawn_offset_y)


## Whole-tick hold a card needs to commit. Cards now commit on the press EDGE
## (no charge/channel time), so EVERY type is a tap — 0. Kept for the AI brain,
## which sizes its "button holds" off this.
func cost_ticks_for_slot(_slot: int) -> int:
	return 0


## True while any spell of OURS sits on the stack awaiting release. The AI
## reads this to avoid countering its own telegraph; the HUD hides the cards.
func is_staging() -> bool:
	return not _staged_queue.is_empty()


## Cooldown ticks left on a slot (0 = ready). HUD dimming hook.
func cooldown_ticks_remaining(slot: int) -> int:
	if slot < 1 or slot > 3:
		return 0
	return _slot_cd[slot - 1]


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

func _network_process(input: Dictionary) -> void:
	for i in 3:
		if _slot_cd[i] > 0:
			_slot_cd[i] -= 1

	var raw_slot: int = InputCommand.get_card(input)
	var press_edge: bool = raw_slot != 0 and raw_slot != _prev_raw_slot

	# The rejection latch follows the RAW key: one card_rejected per press.
	if raw_slot == 0:
		_rejected_slot_latch = 0

	# --- INPUT HANDLING -------------------------------------------------
	var card: CardResource = _card_for_slot(raw_slot) if raw_slot != 0 else null
	var can_act: bool = card != null and _slot_cd[raw_slot - 1] == 0

	if card != null and press_edge and not can_act:
		_reject_once(raw_slot, card)  # pressed a cooling-down slot

	if can_act and card.is_reactive_only and not _stack_window_open():
		# Reactive lock (counters in neutral play): reject once per press.
		if press_edge or _rejected_slot_latch != raw_slot:
			_reject_once(raw_slot, card)
		can_act = false

	# COMMIT ON PRESS (Creative Director: cards have NO charge/channel time — a
	# press commits the card immediately, on the press EDGE). ATTACK and COUNTER
	# go straight ONTO THE STACK (resolved LIFO when the shared window expires);
	# DEFENSE resolves instantly off-stack with its Window of Affect measured at
	# deploy. The per-slot cooldown (started at _stage / deploy) gates re-press.
	if can_act and press_edge:
		match card.card_type:
			CardResource.CardType.DEFENSE:
				# DEFENSE — truly instant, never on the stack.
				_resolve_defense(card)
				card_cast.emit(card)
				_slot_cd[raw_slot - 1] = _cooldown_ticks
			CardResource.CardType.COUNTER:
				# COUNTER — SLAP IT ON THE STACK: latch the WOA (how late into
				# the running countdown this response came) and stage it. The
				# shared clock keeps running; everything resolves LIFO together.
				var woa_fp: int = SGFixed.from_float(clampf(1.0 - _stack_window_fraction(), 0.0, 1.0))
				_stage(raw_slot, woa_fp)
			_:
				# ATTACK — straight onto the stack the instant it is pressed.
				_stage(raw_slot, 0)

	_prev_raw_slot = raw_slot


## Resolves our NEWEST staged spell NOW (pop-back = LIFO within this caster,
## which composes with MatchController's reversed entry walk into global
## LIFO). Called once per stack entry when the shared window expires.
## NETPLAY NOTE: today this call originates from the wall-clock window — it
## becomes a tick-counted release with the rollback sprint.
func release_staged() -> void:
	if _staged_queue.is_empty():
		return
	var slot: int = _staged_queue.pop_back()
	var woa_fp: int = _staged_woas.pop_back()
	var card: CardResource = _card_for_slot(slot)
	if card == null:
		return
	match card.card_type:
		CardResource.CardType.ATTACK:
			_resolve_attack(card)
		CardResource.CardType.COUNTER:
			_resolve_counter(card, woa_fp)
		_:
			push_warning("CardCasterComponent: staged a non-stack card type.")
	card_cast.emit(card)


func _stage(slot: int, woa_fp: int) -> void:
	_staged_queue.append(slot)
	_staged_woas.append(woa_fp)
	_slot_cd[slot - 1] = _cooldown_ticks  # the card has left the hand
	spell_staged.emit(_card_for_slot(slot))


func _reject_once(slot: int, card: CardResource) -> void:
	if _rejected_slot_latch != slot:
		_rejected_slot_latch = slot
		card_rejected.emit(card)


func _save_state() -> Dictionary:
	# The staged queue is fixed-capacity 3 (per-slot cooldown forbids
	# duplicates) — saved as padded int fields, int-only leaves preserved.
	return {
		"cd1": _slot_cd[0],
		"cd2": _slot_cd[1],
		"cd3": _slot_cd[2],
		"sq1": _staged_queue[0] if _staged_queue.size() > 0 else 0,
		"sq2": _staged_queue[1] if _staged_queue.size() > 1 else 0,
		"sq3": _staged_queue[2] if _staged_queue.size() > 2 else 0,
		"wo1": _staged_woas[0] if _staged_woas.size() > 0 else 0,
		"wo2": _staged_woas[1] if _staged_woas.size() > 1 else 0,
		"wo3": _staged_woas[2] if _staged_woas.size() > 2 else 0,
		"pr": _prev_raw_slot,
	}


func _load_state(state: Dictionary) -> void:
	_slot_cd[0] = int(state.get("cd1", 0))
	_slot_cd[1] = int(state.get("cd2", 0))
	_slot_cd[2] = int(state.get("cd3", 0))
	_staged_queue.clear()
	_staged_woas.clear()
	for i in 3:
		var slot: int = int(state.get("sq%d" % (i + 1), 0))
		if slot != 0:
			_staged_queue.append(slot)
			_staged_woas.append(int(state.get("wo%d" % (i + 1), 0)))
	_prev_raw_slot = int(state.get("pr", 0))


## Clean slate for a new round (called by PlayerController.reset_for_round):
## drops any staged spells (and the cooldowns) without firing them.
func reset_cast_state() -> void:
	_slot_cd = [0, 0, 0]
	_staged_queue.clear()
	_staged_woas.clear()
	_prev_raw_slot = 0


# =====================================================================
# Category effects
# =====================================================================

## ATTACK (Category A): projectile_count balls fanned by spread_x_speed,
## fired at STAGE RELEASE from the caster's current position. Homing
## (CardResource.homing_strength) gently curves them toward the enemy wizard.
func _resolve_attack(card: CardResource) -> void:
	if card.projectile_scene == null:
		push_warning("CardCasterComponent: ATTACK card '%s' has no projectile_scene — cast fizzles." % card.display_name)
		spell_cast.emit(null, card)
		return

	var tick_fp: int = SGFixed.from_int(maxi(1, tick_rate))
	var speed_fp: int = SGFixed.div(SGFixed.from_float(card.base_speed), tick_fp)
	# STACK WINNER REWARD: if our wizard won the last stack, this attack flies
	# faster (one-shot, consumed here so a single throw carries it).
	if _body.has_method(&"consume_speed_boost"):
		speed_fp = SGFixed.mul(speed_fp, _body.consume_speed_boost())
	var spread_fp: int = SGFixed.div(SGFixed.from_float(card.spread_x_speed), tick_fp)
	var bounciness_fp: int = SGFixed.from_float(card.bounciness)
	var count: int = clampi(card.projectile_count, 1, 5)
	var target: Node = _find_enemy_wizard()

	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	# NO projectile spawns outside the lane: clamp the spawn ORIGIN so each
	# ball's full radius stays on the court. The fan AND the aim are velocity
	# only (below), so every ball shares this one clamped X and still steers in
	# flight — aiming is preserved, only the origin is pinned inside the map.
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(card.projectile_size), _arena_bound_fp())
	var container: Node = _resolve_container()

	var first: Node = null
	for i in count:
		# Fan index: 0, +1, -1, +2, -2 — center ball first, pairs outward.
		@warning_ignore("integer_division")
		var fan: int = ((i + 1) / 2) * (1 if i % 2 == 1 else -1)

		var projectile: Node = card.projectile_scene.instantiate()
		container.add_child(projectile)
		projectile.set_global_fixed_position(SGFixed.vector2(
				spawn_x,
				caster_pos.y + _spawn_offset_y_fp * cast_direction_y))
		projectile.sync_to_physics_engine()
		# ONE-WAY SHIELDS: this ball ignores its OWNER's barriers.
		projectile.collision_mask = PhysicsLayers.projectile_mask_for(cast_direction_y)

		if projectile.has_method(&"set_hit_source"):
			projectile.set_hit_source(_body)
		if "damage" in projectile:
			projectile.damage = card.damage
		if projectile.has_method(&"apply_size"):
			projectile.apply_size(card.projectile_size)
		if target != null and card.homing_strength > 0.0 and projectile.has_method(&"set_homing"):
			projectile.set_homing(target, SGFixed.from_float(card.homing_strength))
		if "splits_on_barrier" in projectile:
			projectile.splits_on_barrier = card.barrier_breaker
		# Card lifetime overrides the scene default (recache-after-_ready rule).
		for child in projectile.get_children():
			if child is ProjectileMovementComponent:
				child.set_lifespan_seconds(card.lifetime)
				break

		projectile.launch(fan * spread_fp + _aim_vx_fp(speed_fp), speed_fp * cast_direction_y, bounciness_fp)
		if first == null:
			first = projectile

	spell_cast.emit(first, card)


## Lateral launch tilt from the held movement input at release (the staged
## bolt fires where you're steering — same math as SpellCasterComponent).
func _aim_vx_fp(forward_speed_fp: int) -> int:
	if _movement == null or aim_full_hold_ticks <= 0:
		return 0
	var ticks: int = mini(_movement.get_aim_ticks(), aim_full_hold_ticks)
	if ticks <= 0 or _movement.get_aim_dir() == 0:
		return 0
	var fraction_fp: int = SGFixed.div(SGFixed.from_int(ticks), SGFixed.from_int(aim_full_hold_ticks))
	var max_vx_fp: int = SGFixed.mul(forward_speed_fp, SGFixed.from_float(clampf(aim_max_fraction, 0.0, 1.0)))
	return _movement.get_aim_dir() * SGFixed.mul(max_vx_fp, fraction_fp)


## DEFENSE (Category B): INSTANT one-way wall, with the Window of Affect
## measured NOW (how close the nearest incoming ball already is).
func _resolve_defense(card: CardResource) -> void:
	if card.barrier_scene == null:
		push_warning("CardCasterComponent: DEFENSE card '%s' has no barrier_scene — cast fizzles." % card.display_name)
		spell_cast.emit(null, card)
		return

	var barrier: Node = card.barrier_scene.instantiate()
	_resolve_container().add_child(barrier)

	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	# Clamp the wall ORIGIN so its full half-width (wall_size.x * 0.5) stays in
	# the lane — a wall deployed at the edge no longer pokes through the arena.
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(card.wall_size.x * 0.5), _arena_bound_fp())
	barrier.set_global_fixed_position(SGFixed.vector2(
			spawn_x,
			caster_pos.y + SGFixed.from_float(card.wall_offset_y) * cast_direction_y))
	# ONE-WAY: the barrier lives on this SIDE's layer; only ENEMY projectiles
	# (whose mask includes it) collide. Layer set BEFORE the engine sync.
	barrier.collision_layer = PhysicsLayers.barrier_layer_for(cast_direction_y)
	barrier.sync_to_physics_engine()

	var safe_tick_rate: int = maxi(1, tick_rate)
	var lifespan_ticks: int = 0 if card.wall_lifetime <= 0.0 \
			else maxi(1, ceili(card.wall_lifetime * float(safe_tick_rate)))
	var move_fp: int = SGFixed.div(
			SGFixed.from_float(card.wall_movement_speed),
			SGFixed.from_int(safe_tick_rate))

	# WINDOW OF AFFECT: pure fixed-point distance scan at deploy time.
	var woa_fp: int = _defense_woa_fp(card)
	var hold_ticks: int = (SGFixed.mul(woa_fp, SGFixed.from_float(card.woa_max_hold_seconds * float(safe_tick_rate)))) >> 16
	var reflect_mult_fp: int = SGFixed.ONE + SGFixed.mul(woa_fp, SGFixed.from_float(maxf(0.0, card.woa_max_reflect - 1.0)))
	# Ricochet = a 0.6 lateral base on EVERY block (~+15 degrees over the old
	# 0.3 — Creative Director) + the card's WOA-scaled harshness (can exceed
	# 1 = steeper than diagonal — wall-carom territory).
	var ricochet_fp: int = SGFixed.from_float(0.6) + SGFixed.mul(woa_fp, SGFixed.from_float(maxf(0.0, card.woa_ricochet)))

	if barrier.has_method(&"deploy"):
		barrier.deploy(
				SGFixed.from_float(card.wall_size.x * 0.5),
				SGFixed.from_float(card.wall_size.y * 0.5),
				lifespan_ticks,
				move_fp)
	if barrier.has_method(&"arm_window_of_affect"):
		barrier.arm_window_of_affect(_body, -cast_direction_y, woa_fp, hold_ticks,
				reflect_mult_fp, ricochet_fp,
				PhysicsLayers.projectile_mask_for(cast_direction_y))

	spell_cast.emit(barrier, card)


## COUNTER (Category C): the staged frost wave, released LIFO with the WOA
## latched at the slap moment. Floats here convert ONCE at release.
func _resolve_counter(card: CardResource, woa_fp: int) -> void:
	if card.projectile_scene == null:
		push_warning("CardCasterComponent: COUNTER card '%s' has no projectile_scene — cast fizzles." % card.display_name)
		spell_cast.emit(null, card)
		return

	var woa: float = clampf(woa_fp / 65536.0, 0.0, 1.0)
	var slow_scale: float = lerpf(card.slow_scale_weak, card.slow_scale_strong, woa)
	var safe_tick_rate: int = maxi(1, tick_rate)

	var wave: Node = card.projectile_scene.instantiate()
	_resolve_container().add_child(wave)
	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	# THE ICEY RETORT FIX: the frost wave is wide (half-width = projectile_size,
	# 200u). It resolves at window-close from the caster's THEN-current position,
	# so if the caster walked to the lane edge during the slow-mo window the wave
	# used to spawn ~150u past the wall. Clamp the origin so the whole wave stays
	# on the court. Launch vx is 0 here — aim never touched this spell anyway.
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(card.projectile_size), _arena_bound_fp())
	wave.set_global_fixed_position(SGFixed.vector2(
			spawn_x,
			caster_pos.y + _spawn_offset_y_fp * cast_direction_y))
	wave.sync_to_physics_engine()
	wave.collision_mask = PhysicsLayers.projectile_mask_for(cast_direction_y)

	if wave.has_method(&"set_hit_source"):
		wave.set_hit_source(_body)
	# The court-wide frost wave never spews side-wall pulses (Sprint 20): it is
	# wide and travels straight, so a clipped corner must not flash mid-court.
	if "emits_wall_pulse" in wave:
		wave.emits_wall_pulse = false
	if "damage" in wave:
		wave.damage = card.damage
	if "slow_ticks" in wave:
		wave.slow_ticks = maxi(1, ceili(card.slow_duration * float(safe_tick_rate)))
		wave.slow_scale_fp = SGFixed.from_float(clampf(slow_scale, 0.0, 1.0))

	var speed_fp: int = SGFixed.div(SGFixed.from_float(card.base_speed), SGFixed.from_int(safe_tick_rate))
	wave.launch(0, speed_fp * cast_direction_y, SGFixed.ONE)

	spell_cast.emit(wave, card)


# =====================================================================
# Internals
# =====================================================================

## Defense WOA: ONE - (nearest incoming ball's down-court distance / range),
## clamped 0..ONE. Pure fixed-point ints. Balls our own wizard threw (or far
## off our lane) don't count.
func _defense_woa_fp(card: CardResource) -> int:
	var range_fp: int = SGFixed.from_float(maxf(1.0, card.woa_range))
	var lateral_gate_fp: int = SGFixed.from_float(300.0)
	var my_pos: SGFixedVector2 = _body.get_global_fixed_position()
	var best: int = range_fp
	var container: Node = _resolve_container()
	for child in container.get_children():
		if not child.has_method(&"get_velocity_y") or not child.has_method(&"get_hit_source"):
			continue
		if child.get_hit_source() == _body:
			continue  # our own throw
		var ball_pos: SGFixedVector2 = child.get_global_fixed_position()
		var dy: int = my_pos.y - ball_pos.y
		var vy: int = child.get_velocity_y()
		if vy == 0 or (vy > 0) != (dy > 0):
			continue  # not incoming
		if absi(my_pos.x - ball_pos.x) > lateral_gate_fp:
			continue  # not our lane
		best = mini(best, absi(dy))
	return clampi(SGFixed.ONE - SGFixed.div(best, range_fp), 0, SGFixed.ONE)


## The lane half-width (fixed-point) spawns clamp to — the SAME bound the wizard
## BODY is clamped to, read from our sibling MovementComponent so scene
## overrides win (400 in match_arena, 500 in test_area, 600 default). Only the
## defensive fallback fires if no MovementComponent sibling resolved.
func _arena_bound_fp() -> int:
	if _movement != null:
		return _movement.arena_half_width_fp()
	return SGFixed.from_float(400.0)


## The other wizard in the "wizards" group (homing target). Deterministic:
## first group member that isn't our own body.
func _find_enemy_wizard() -> Node:
	for wizard in get_tree().get_nodes_in_group(&"wizards"):
		if wizard != _body:
			return wizard
	return null


func _card_for_slot(slot: int) -> CardResource:
	match slot:
		1: return card_slot_1
		2: return card_slot_2
		3: return card_slot_3
	return null


## Is The Stack's time-slow window open? (NETPLAY: the single wall-clock call
## site that goes tick-counted with rollback.)
func _stack_window_open() -> bool:
	var stack: Node = get_node_or_null(^"/root/TheStack")
	return stack != null and stack.state == stack.State.STACK_WINDOW


## 0..1 of the current window remaining (0 when closed) — the counter WOA.
func _stack_window_fraction() -> float:
	var stack: Node = get_node_or_null(^"/root/TheStack")
	if stack == null:
		return 0.0
	return stack.window_fraction_remaining()


func _resolve_container() -> Node:
	if not projectile_container_path.is_empty():
		var container: Node = get_node_or_null(projectile_container_path)
		if container != null:
			return container
		push_warning("CardCasterComponent: projectile_container_path not found — falling back to the caster body's parent.")
	return _body.get_parent()


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
