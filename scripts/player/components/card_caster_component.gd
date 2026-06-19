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
# Sibling SpellCasterComponent (the base fireball) — receives the Focus Sigil fireball-haste buff.
var _spell_caster: SpellCasterComponent = null
# StackResolver (sim authority for the window) — found lazily via its group so
# scene-tree _ready order never matters. Holds the deterministic resolution clock
# that this caster arms when it stages (Sprint 22 Phase 2).
var _resolver: Node = null


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "CardCasterComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	for child in _body.get_children():
		if child is MovementComponent:
			_movement = child
		elif child is SpellCasterComponent:
			_spell_caster = child
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


## SHIELD-REFLECT RALLY (Creative Director): a barrier just reflected a ball back at this wizard —
## clear the DEFENSE slot's cooldown so the player can immediately re-block and keep the rally going
## (the cast gate is `_slot_cd[slot-1] == 0`). Called deterministically from BarrierController._tick_capture
## (a sim tick) so both peers re-enable on the SAME tick; the cooldown is saved state ("cd1/2/3"), so a
## rollback restores it and an idempotent re-clear stays in lockstep. Sparks shatter the wall (never reach
## release), so this never fires for them — matching "it won't happen with sparks".
func make_defense_available() -> void:
	for slot in range(1, 4):
		var card: CardResource = _card_for_slot(slot)
		if card != null and card.card_type == CardResource.CardType.DEFENSE:
			_slot_cd[slot - 1] = 0
			return


## Whether the equipped DEFENSE card is a BUFF (buff_duration > 0) rather than a shield/wall. The card
## hand HUD reads this (duck-typed) so a buff defense card shows whenever it is off cooldown — a buff is
## proactive, not reactive like the shield, so it must not be gated on an incoming ball.
func is_defense_buff() -> bool:
	for slot in range(1, 4):
		var card: CardResource = _card_for_slot(slot)
		if card != null and card.card_type == CardResource.CardType.DEFENSE:
			return card.buff_duration > 0.0
	return false


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
				_emit_card_cast(card)
				_slot_cd[raw_slot - 1] = _cooldown_ticks
			CardResource.CardType.COUNTER:
				# COUNTER — SLAP IT ON THE STACK: latch the WOA (how late into
				# the running countdown this response came) and stage it. The
				# shared clock keeps running; everything resolves LIFO together.
				var woa_fp: int = _counter_woa_fp()
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
	_emit_card_cast(card)


func _stage(slot: int, woa_fp: int) -> void:
	_staged_queue.append(slot)
	_staged_woas.append(woa_fp)
	_slot_cd[slot - 1] = _cooldown_ticks  # the card has left the hand
	# SIM-SIDE STACK CLOCK (Sprint 22 Phase 2): arm the deterministic resolver from
	# THIS tick (idempotent — a slap onto an open window keeps the shared clock) and
	# record our side so the last responder wins the stack. Done here, in the caster's
	# own _network_process, so it rolls back identically — never via TheStack (whose
	# wall-clock state isn't synced).
	var resolver: Node = _get_resolver()
	if resolver != null:
		resolver.arm(_resolver_window_ticks())
		resolver.notify_staged(1 if cast_direction_y < 0 else 2)
	_emit_spell_staged(_card_for_slot(slot))


func _reject_once(slot: int, card: CardResource) -> void:
	if _rejected_slot_latch != slot:
		_rejected_slot_latch = slot
		_emit_card_rejected(card)


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
		_emit_spell_cast(null, card)
		return

	var tick_fp: int = SGFixed.from_int(maxi(1, tick_rate))
	var speed_fp: int = SGFixed.div(SGFixed.from_float(card.base_speed), tick_fp)
	# STACK WINNER REWARD: if our wizard won the last stack, this attack flies
	# faster (one-shot, consumed HERE in the caster's tick so it rolls back).
	if _body.has_method(&"consume_speed_boost"):
		speed_fp = SGFixed.mul(speed_fp, _body.consume_speed_boost())
	var spread_fp: int = SGFixed.div(SGFixed.from_float(card.spread_x_speed), tick_fp)
	var bounciness_fp: int = SGFixed.from_float(card.bounciness)
	var count: int = clampi(card.projectile_count, 1, 5)
	var aim_vx_fp: int = _aim_vx_fp(speed_fp)  # same held-aim for every ball this tick
	var target: Node = _find_enemy_wizard()
	var homes: bool = target != null and card.homing_strength > 0.0

	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	# NO projectile spawns outside the lane: clamp the spawn ORIGIN so each ball's full
	# radius stays on the court. Fan + aim are velocity only, so every ball shares this
	# one clamped X and still steers in flight.
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(card.projectile_size), _arena_bound_fp())
	var spawn_y: int = caster_pos.y + _spawn_offset_y_fp * cast_direction_y
	var mask: int = PhysicsLayers.projectile_mask_for(cast_direction_y)
	var life_ticks: int = 0 if card.lifetime <= 0.0 else maxi(1, ceili(card.lifetime * float(maxi(1, tick_rate))))
	var container: Node = _resolve_container()
	var sm: Node = _sync_manager()

	var first: Node = null
	for i in count:
		# Fan index: 0, +1, -1, +2, -2 — center ball first, pairs outward.
		@warning_ignore("integer_division")
		var fan: int = ((i + 1) / 2) * (1 if i % 2 == 1 else -1)
		# ROLLBACK SPAWN (Sprint 22 Phase 2b): pure int/path payload — FireballController.
		# _network_spawn rebuilds the ball identically on the spawn tick and every re-sim.
		# Homing target rides as an ABSOLUTE path (node refs aren't serializable).
		var data := {
			"px": spawn_x, "py": spawn_y,
			"vx": fan * spread_fp + aim_vx_fp, "vy": speed_fp * cast_direction_y, "b": bounciness_fp,
			"mask": mask,
			"dmg": card.damage,
			"elem": card.element,
			"size": SGFixed.from_float(card.projectile_size),
			"split": 1 if card.barrier_breaker else 0,
			"life": life_ticks,
			"src": str(_body.get_path()),
		}
		if homes:
			data["tgt"] = str(target.get_path())
			data["hstr"] = SGFixed.from_float(card.homing_strength)
		var projectile: Node = sm.spawn("CardBolt", container, card.projectile_scene, data)
		if first == null:
			first = projectile

	_emit_spell_cast(first, card)


## Lateral launch tilt from the unified AIM SECTOR (Mobile-MP B2; same math as
## SpellCasterComponent): vx = forward_speed x aim_max_fraction x (sector / AIM_SECTORS).
## The staged bolt fires where you're steering -- the touch joystick's firing angle, or
## the keyboard's held-direction duration on the same scale. Pure fixed-point (no trig).
func _aim_vx_fp(forward_speed_fp: int) -> int:
	if _movement == null:
		return 0
	var sector: int = _aim_sector_now()
	if sector == 0:
		return 0
	var lateral_fp: int = SGFixed.div(SGFixed.from_int(sector), SGFixed.from_int(InputCommand.AIM_SECTORS))
	var max_vx_fp: int = SGFixed.mul(forward_speed_fp, SGFixed.from_float(clampf(aim_max_fraction, 0.0, 1.0)))
	return SGFixed.mul(max_vx_fp, lateral_fp)


## The unified aim SECTOR in [-AIM_SECTORS, +AIM_SECTORS] (0 = straight down-court):
## the TOUCH joystick's KEY_AIM when present, else the KEYBOARD's held-direction
## duration mapped onto the same scale (aim_dir x ticks/full x N, integer -> the old
## hold-to-tilt feel, quantized). Move + aim together: the stick's lateral push both
## steers and aims; on keys, holding a direction longer steepens the throw.
func _aim_sector_now() -> int:
	var touch: int = _movement.get_aim_key()
	if touch != 0:
		return clampi(touch, -InputCommand.AIM_SECTORS, InputCommand.AIM_SECTORS)
	if aim_full_hold_ticks <= 0:
		return 0
	var ticks: int = clampi(_movement.get_aim_ticks(), 0, aim_full_hold_ticks)
	return _movement.get_aim_dir() * ticks * InputCommand.AIM_SECTORS / aim_full_hold_ticks


## DEFENSE (Category B): INSTANT one-way wall, with the Window of Affect
## measured NOW (how close the nearest incoming ball already is).
func _resolve_defense(card: CardResource) -> void:
	# BUFF archetype (Content Engine): a DEFENSE card with buff_duration > 0 applies a timed SELF-BUFF to
	# the caster instead of deploying a barrier. Deterministic sim state on the caster's MovementComponent
	# (fixed-point, saved/rolled-back) — online-safe by construction, exactly like every other card effect.
	if card.buff_duration > 0.0:
		_resolve_buff(card)
		return
	if card.barrier_scene == null:
		push_warning("CardCasterComponent: DEFENSE card '%s' has no barrier_scene — cast fizzles." % card.display_name)
		_emit_spell_cast(null, card)
		return

	var safe_tick_rate: int = maxi(1, tick_rate)
	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	# Clamp the wall ORIGIN so its full half-width stays in the lane.
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(card.wall_size.x * 0.5), _arena_bound_fp())
	var lifespan_ticks: int = 0 if card.wall_lifetime <= 0.0 \
			else maxi(1, ceili(card.wall_lifetime * float(safe_tick_rate)))
	var move_fp: int = SGFixed.div(
			SGFixed.from_float(card.wall_movement_speed),
			SGFixed.from_int(safe_tick_rate))

	# WINDOW OF AFFECT: pure fixed-point distance scan at deploy time (the caster's tick,
	# so it reads rolled-back ball positions). Precomputed here; the barrier reconstructs
	# from these ints in _network_spawn.
	var woa_fp: int = _defense_woa_fp(card)
	var hold_ticks: int = (SGFixed.mul(woa_fp, SGFixed.from_float(card.woa_max_hold_seconds * float(safe_tick_rate)))) >> 16
	var reflect_mult_fp: int = SGFixed.ONE + SGFixed.mul(woa_fp, SGFixed.from_float(maxf(0.0, card.woa_max_reflect - 1.0)))
	# Ricochet = a 0.6 lateral base on EVERY block + the card's WOA-scaled harshness.
	var ricochet_fp: int = SGFixed.from_float(0.6) + SGFixed.mul(woa_fp, SGFixed.from_float(maxf(0.0, card.woa_ricochet)))

	# ROLLBACK SPAWN (Sprint 22 Phase 2b): int/path payload. BarrierController._network_spawn
	# calls deploy() + arm_window_of_affect() from it; the one-way layer is set there BEFORE
	# the engine sync, and the owner wizard is resolved by its stable scene path.
	var data := {
		"px": spawn_x, "py": caster_pos.y + SGFixed.from_float(card.wall_offset_y) * cast_direction_y,
		"layer": PhysicsLayers.barrier_layer_for(cast_direction_y),
		"hw": SGFixed.from_float(card.wall_size.x * 0.5),
		"hh": SGFixed.from_float(card.wall_size.y * 0.5),
		"life": lifespan_ticks,
		"move": move_fp,
		"owner": str(_body.get_path()),
		"hdir": -cast_direction_y,
		"woa": woa_fp,
		"hold": hold_ticks,
		"refl": reflect_mult_fp,
		"ric": ricochet_fp,
		"rmask": PhysicsLayers.projectile_mask_for(cast_direction_y),
	}
	var barrier: Node = _sync_manager().spawn("Barrier", _resolve_container(), card.barrier_scene, data)

	_emit_spell_cast(barrier, card)


## BUFF (Category B sub-type): apply the card's timed self-buffs to the caster — currently a movement
## speed boost (Hermes' Boon). Floats convert to fixed-point + whole ticks ONCE here (the caster's tick);
## the MovementComponent owns the int countdown thereafter. No projectile/barrier — emits a null cast.
func _resolve_buff(card: CardResource) -> void:
	var safe_tick_rate: int = maxi(1, tick_rate)
	var duration_ticks: int = maxi(1, ceili(card.buff_duration * float(safe_tick_rate)))
	if card.move_speed_buff > 1.0 and _movement != null:
		_movement.apply_timed_boost(duration_ticks, SGFixed.from_float(card.move_speed_buff))
	if card.fireball_haste < 1.0 and _spell_caster != null:
		_spell_caster.apply_timed_haste(duration_ticks, SGFixed.from_float(card.fireball_haste))
	_emit_spell_cast(null, card)


## COUNTER (Category C): the staged frost wave, released LIFO with the WOA
## latched at the slap moment. Floats here convert ONCE at release.
func _resolve_counter(card: CardResource, woa_fp: int) -> void:
	if card.projectile_scene == null:
		push_warning("CardCasterComponent: COUNTER card '%s' has no projectile_scene — cast fizzles." % card.display_name)
		_emit_spell_cast(null, card)
		return

	var safe_tick_rate: int = maxi(1, tick_rate)
	# WOA -> slow scale, ALL fixed-point (the old float lerp was a cross-peer desync
	# risk): weak + (strong - weak) * woa, clamped 0..ONE.
	var woa_clamped: int = clampi(woa_fp, 0, SGFixed.ONE)
	var weak_fp: int = SGFixed.from_float(card.slow_scale_weak)
	var strong_fp: int = SGFixed.from_float(card.slow_scale_strong)
	var slow_scale_fp: int = clampi(weak_fp + SGFixed.mul(strong_fp - weak_fp, woa_clamped), 0, SGFixed.ONE)

	var caster_pos: SGFixedVector2 = _body.get_global_fixed_position()
	# THE ICEY RETORT FIX: the frost wave is wide; clamp its ORIGIN so the whole wave
	# stays on the court even if the caster walked to the lane edge during the window.
	var spawn_x: int = MovementComponent.clamp_spawn_x_fp(
			caster_pos.x, SGFixed.from_float(card.projectile_size), _arena_bound_fp())
	var speed_fp: int = SGFixed.div(SGFixed.from_float(card.base_speed), SGFixed.from_int(safe_tick_rate))
	# ROLLBACK SPAWN (Sprint 22 Phase 2b): int-only payload. vx 0 (aim never touched the
	# wave), pulse off (a court-wide wave must not flash side-wall pulses), damage 0,
	# frost slow armed (slt/sls). FireballController._network_spawn rebuilds it.
	var data := {
		"px": spawn_x, "py": caster_pos.y + _spawn_offset_y_fp * cast_direction_y,
		"vx": 0, "vy": speed_fp * cast_direction_y, "b": SGFixed.ONE,
		"mask": PhysicsLayers.projectile_mask_for(cast_direction_y),
		"dmg": card.damage,
		"elem": card.element,
		"slt": maxi(1, ceili(card.slow_duration * float(safe_tick_rate))),
		"sls": slow_scale_fp,
		"pulse": 0,
		"src": str(_body.get_path()),
	}
	var wave: Node = _sync_manager().spawn("FrostWave", _resolve_container(), card.projectile_scene, data)

	_emit_spell_cast(wave, card)


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


## PRESENTATION (Sprint 23 batch 3, revised — Creative Director): true when ANY hostile projectile is
## moving TOWARD our wizard's baseline, regardless of lane or distance — drives the DEFENSE card popping
## into the hand whenever there's an attack on the way to block. The old version also gated on a 650-unit
## range AND a 300-unit lane band, so a ball that flew off-angle dropped out of "threat" and only
## re-popped on its wall-bounce, leaving no time to ready a block. Now it is purely DIRECTIONAL: is it
## coming at me. Pure read (never sim/saved); the emerald is skipped for free (it exposes no get_velocity_y).
func has_incoming_threat() -> bool:
	if _body == null:
		return false
	var my_pos: SGFixedVector2 = _body.get_global_fixed_position()
	var container: Node = _resolve_container()
	if container == null:
		return false
	for child in container.get_children():
		if not child.has_method(&"get_velocity_y") or not child.has_method(&"get_hit_source"):
			continue
		if child.get_hit_source() == _body:
			continue  # our own throw
		var ball_pos: SGFixedVector2 = child.get_global_fixed_position()
		var dy: int = my_pos.y - ball_pos.y
		var vy: int = child.get_velocity_y()
		if vy == 0 or (vy > 0) != (dy > 0):
			continue  # moving away / already past us — not coming toward our baseline
		return true  # a hostile ball is heading our way (any lane, any distance)
	return false


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


## The rollback spawn authority, resolved by /root node path instead of the bare
## `SyncManager` autoload global. That identifier does NOT resolve at COMPILE time in this
## script (it does in spell_caster / fireball_controller): card_caster lands in the compile
## graph early — pulled in by AIBrainComponent — before the autoload registers as a GDScript
## global, so a bare reference is "Identifier not found". The /root lookup is order-free.
func _sync_manager() -> Node:
	return get_node_or_null(^"/root/SyncManager")


## True while SyncManager is RE-SIMULATING a corrected tick. The card-presentation
## emitters below are guarded on this so a rollback correction never re-fires the
## HUD/VFX/SFX (Creative Director playtest: online, the stack double-stacked shaking
## cards + a desynced countdown). The SIM — staging, spawns, cooldowns — runs every
## re-sim regardless; ONLY these presentation hooks are suppressed.
func _is_in_rollback() -> bool:
	var sm: Node = _sync_manager()
	return sm != null and sm.is_in_rollback()


func _emit_card_cast(card: CardResource) -> void:
	if not _is_in_rollback():
		card_cast.emit(card)


func _emit_spell_cast(node: Node, spell: Object) -> void:
	if not _is_in_rollback():
		spell_cast.emit(node, spell)


func _emit_spell_staged(card: CardResource) -> void:
	if not _is_in_rollback():
		spell_staged.emit(card)


func _emit_card_rejected(card: CardResource) -> void:
	if not _is_in_rollback():
		card_rejected.emit(card)


func _card_for_slot(slot: int) -> CardResource:
	match slot:
		1: return card_slot_1
		2: return card_slot_2
		3: return card_slot_3
	return null


## The StackResolver — the deterministic, rolled-back sim authority for the window
## (Sprint 22 Phase 2). Found lazily via its group so scene-tree _ready order is
## irrelevant; cached once resolved.
func _get_resolver() -> Node:
	if _resolver == null or not is_instance_valid(_resolver):
		_resolver = get_tree().get_first_node_in_group(&"stack_resolver")
	return _resolver


## Is a stack window open? Now a deterministic SIM read (the resolver's countdown),
## not TheStack's wall clock — so the counter reactive-lock rolls back correctly.
func _stack_window_open() -> bool:
	var resolver: Node = _get_resolver()
	return resolver != null and resolver.is_window_open()


## Counter WOA as fixed-point: 1 - (window remaining fraction). All-int, read from the
## resolver's tick state, so it is identical on both peers (the wall-clock float read
## was the desync hole this closes). 0 when no window is open.
func _counter_woa_fp() -> int:
	var resolver: Node = _get_resolver()
	if resolver == null:
		return 0
	return clampi(SGFixed.ONE - resolver.window_fraction_fp(), 0, SGFixed.ONE)


## Whole sim ticks the resolution window lasts. It must span the SAME real time as the
## wall-clock presentation countdown (default_window_seconds) so spells resolve exactly
## when the on-screen timer hits zero. Sim ticks advance at the fixed tick_rate REGARDLESS
## of the slow-mo: Engine.time_scale scales each tick's DELTA (motion looks slow) but NOT
## how often _physics_process fires, so the resolver still counts tick_rate ticks per real
## second. Hence seconds x tick_rate (3.0 x 60 = 180) — NOT x stack_time_scale: that 0.1
## factor made it resolve in ~0.3 s ("spells resolve instantly" regression). Read fresh
## from TheStack so Director/test tuning of the window length still drives the sim window.
func _resolver_window_ticks() -> int:
	var stack: Node = get_node_or_null(^"/root/TheStack")
	var seconds: float = 3.0
	if stack != null:
		seconds = stack.default_window_seconds
	return maxi(1, ceili(seconds * float(maxi(1, tick_rate))))


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
