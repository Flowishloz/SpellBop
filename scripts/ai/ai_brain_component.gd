## ai_brain_component.gd — Deterministic AI input source for an opponent wizard.
##
## ARCHITECTURE: the AI is NOT a second control system — it is an INPUT SOURCE.
## Each tick, PlayerController asks this component for an InputCommand
## dictionary ({"x": -1|0|1, "c": 0|1}) instead of polling the keyboard, and
## the exact same buffer -> movement -> caster pipeline runs. In netplay the
## AI's inputs are synced and rolled back exactly like a human's keystrokes —
## zero new simulation code paths.
##
## DETERMINISM: decisions are pure functions of (deterministic sim state,
## tick counter). All position/velocity reads are fixed-point ints compared
## with int math; casting uses a tick-interval counter — NO floats in
## decisions, NO RNG. Float @exports are converted once in _ready(), same
## tuning model as MovementComponent.
##
## CURRENT BRAIN (Sprint 3 — "simple AI for starters"): dodge the nearest
## incoming fireball laterally; otherwise shadow the target player's X
## (rally positioning); cast on a fixed tick interval (the caster's cooldown
## still gates it). EXPANSION SEAM: decide() is the single entry point —
## card play and strategic thinking later replace/extend its internals
## without touching the input pipeline.
class_name AIBrainComponent
extends Node

## Container whose children are live projectiles (FireballController nodes).
## Default assumes the arena shape: Arena/Opponent/AIBrain + Arena/Projectiles.
@export var projectile_container_path: NodePath = NodePath("../../Projectiles")

## The body this AI plays against (shadowed for rally positioning). Default
## assumes the arena shape: Arena/Player.
@export var target_body_path: NodePath = NodePath("../../Player")

## Path to this AI's own SGCharacterBody2D. Leave empty to use the direct
## parent (recommended scene shape: Opponent (PlayerController) -> AIBrain).
@export var body_path: NodePath

## Only fireballs within this many sim units of down-court (Y) distance are
## considered threats. Larger = the AI reacts earlier. (Softened from 1400 —
## Creative Director: the AI was too hard.)
@export var reaction_distance: float = 1000.0

## Lateral (X) half-width, in sim units, inside which an incoming fireball is
## "aimed at me" and triggers a dodge. Tune ~ ball radius + body width + margin.
@export var dodge_radius: float = 140.0

## Deadzone, in sim units, around the target's X before the AI bothers to
## shadow-step. Prevents jittery left/right oscillation.
@export var track_deadzone: float = 40.0

## Cast the equipped spell every N ticks (the SpellCasterComponent cooldown
## still applies). Deterministic counter — no RNG. <= 0 disables casting.
@export var cast_interval_ticks: int = 210

## Consecutive ticks the AI HOLDS the cast bit per cast attempt. Must exceed
## the spell's cast_time in ticks (0.5 s = 30 @ 60 Hz) or the charge never
## completes — the AI "holds the button" exactly like a human holding Space.
## RELEASE-FIRE NOTE: the throw happens when this hold ENDS. The brain varies
## the hold per cast (see hold_variation_ticks) so the AI shows off all three
## Mario-Kart charge levels instead of metronome 1x throws.
@export var cast_hold_ticks: int = 45

## Extra hold added per cast in a deterministic 0/1/2 cycle (hold, hold+v,
## hold+2v) — charge-level variety with zero RNG. 0 = constant holds.
## (Softened from 22: the AI's big charges hit too hard.)
@export var hold_variation_ticks: int = 12

## Play the ATTACK card every N ticks. Slots 2/3 are reactive — see the
## wall/counter logic. <= 0 disables ALL card play (test pin).
@export var card_interval_ticks: int = 660

## Extra ticks held past the card's casting cost (release slack, like a
## human's finger lifting late).
@export var card_hold_margin_ticks: int = 15

## React to an opponent's Stack window: when the time-slow opens and a
## hostile ball is incoming, hold the COUNTER card (slot 3). Reading the
## Stack state is an INPUT decision (the AI "sees" the slow-mo exactly like
## a human does) — produced inputs still sync/replay identically in netplay.
@export var counter_enabled: bool = true

## HUMAN-ISH REACTION TIME (Creative Director: the AI reacted too fast):
## ticks between a threat appearing and the AI dodging / walling it.
## 30 ticks = 0.5 s of "noticing". The clock RE-ARMS whenever a NEW hostile
## ball joins the rally (the old version stayed "pre-reacted" through a
## whole rally — that's why reactions still felt instant).
@export var reaction_delay_ticks: int = 30

## Ticks after an enemy spell hits the stack before the AI reaches for its
## counter (reading the card takes a moment — and during slow-mo these sim
## ticks stretch much further in real time: 14 ticks ≈ 2.3 real seconds of
## the 3.5 s window left uncontested for the player).
@export var counter_delay_ticks: int = 14

## The AI only attempts a counter on every Nth enemy stack window
## (deterministic cycle — it "saves" its counter sometimes). 2 = every other.
@export var counter_every_n_windows: int = 2

# --- Cached fixed-point values (computed once in _ready()) ---
var _reaction_fp: int = 0
var _dodge_fp: int = 0
var _deadzone_fp: int = 0

# Remaining ticks of the current "button hold". Input-source state, NOT sim
# state: the brain produces inputs (like a human's fingers); under rollback
# only the produced inputs are synced/replayed, never this counter.
var _cast_hold_remaining: int = 0

# Card-play input-source state: remaining hold ticks, the slot being held,
# and deterministic cycle counters (cast variety / card alternation).
var _card_hold_remaining: int = 0
var _card_slot: int = 0
var _cast_cycle: int = 0
var _card_cycle: int = 0

# Reaction-time state (input-source, not sim): the tick a threat / an enemy
# stack window was FIRST noticed (-1 = none). Reactions wait out the delay.
# _known_hostiles re-arms the clock when ANOTHER ball joins the rally.
var _threat_since_tick: int = -1
var _known_hostiles: int = 0
var _window_since_tick: int = -1
var _window_cycle: int = 0

var _body: SGCharacterBody2D
var _container: Node
var _target: SGCharacterBody2D
var _card_caster: CardCasterComponent
var _stack: Node


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "AIBrainComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	_container = get_node_or_null(projectile_container_path)
	_target = get_node_or_null(target_body_path) as SGCharacterBody2D
	_reaction_fp = SGFixed.from_float(maxf(0.0, reaction_distance))
	_dodge_fp = SGFixed.from_float(maxf(0.0, dodge_radius))
	_deadzone_fp = SGFixed.from_float(maxf(0.0, track_deadzone))
	# The brain sizes its card "button holds" from the caster's cost math
	# (reading static tuning, not sim state).
	for child in _body.get_children():
		if child is CardCasterComponent:
			_card_caster = child
			break
	_stack = get_node_or_null(^"/root/TheStack")


## THE INPUT SOURCE. Called by PlayerController._get_local_input() each tick.
## Returns a compact int-only InputCommand dictionary, exactly like
## InputCommand.capture_local() — keys omitted when zero.
func decide(tick: int) -> Dictionary:
	var input: Dictionary = {}

	var my_pos: SGFixedVector2 = _body.get_global_fixed_position()

	# REACTION CLOCK: note when a threat first appears; reactions (dodge /
	# reactive wall) only engage after reaction_delay_ticks of "noticing".
	# Each ADDITIONAL hostile joining the rally re-arms the clock, so every
	# new throw gets its own human reaction delay.
	var hostiles_now: int = _hostile_ball_count(my_pos, _reaction_fp)
	if hostiles_now > 0:
		if _threat_since_tick == -1 or hostiles_now > _known_hostiles:
			_threat_since_tick = tick
	else:
		_threat_since_tick = -1
	_known_hostiles = hostiles_now
	var has_reacted: bool = _threat_since_tick != -1 \
			and tick - _threat_since_tick >= reaction_delay_ticks

	var x_dir: int = _decide_x(my_pos, has_reacted)
	if x_dir != 0:
		input[InputCommand.KEY_X] = x_dir

	# CARD PLAY — proactive: tap the ATTACK card (slot 1) on the interval. Cards
	# now COMMIT ON PRESS (no channel), so this is a short hold just to register
	# the press edge (_card_hold_ticks_for returns a tap).
	if card_interval_ticks > 0 and tick % card_interval_ticks == 0 and _card_hold_remaining == 0:
		_card_slot = 1
		_card_cycle += 1
		_card_hold_remaining = _card_hold_ticks_for(1)

	# CARD PLAY — reactive wall: a hostile ball is CLOSE (the high-WOA
	# last-second block) — tap DEFENSE (slot 2). The time-slice gate makes
	# the AI miss roughly half its blocks deterministically (human-ish, no
	# RNG; softened — the AI was too hard). card_interval_ticks <= 0
	# disables ALL card play (test pin).
	@warning_ignore("integer_division")
	var wall_window_open: bool = ((tick / 20) % 3) == 0
	if card_interval_ticks > 0 and _card_hold_remaining == 0 and wall_window_open \
			and has_reacted \
			and _hostile_ball_incoming(my_pos, SGFixed.from_float(350.0)):
		_card_slot = 2
		_card_hold_remaining = _card_hold_ticks_for(2)

	# CARD PLAY — reactive: an ENEMY spell is on the stack (time-slow window
	# open and it isn't OUR staging) — after a reading delay, tap the
	# COUNTER (slot 3).
	var enemy_window_open: bool = _stack != null \
			and _stack.state == _stack.State.STACK_WINDOW \
			and (_card_caster == null or not _card_caster.is_staging())
	if enemy_window_open:
		if _window_since_tick == -1:
			_window_since_tick = tick
			_window_cycle += 1
	else:
		_window_since_tick = -1
	# Counter only every Nth window (it "saves" the response sometimes) and
	# only after the reading delay — the player owns the window's first beat.
	var counter_this_window: bool = counter_every_n_windows <= 1 \
			or (_window_cycle % maxi(1, counter_every_n_windows)) == 1
	if counter_enabled and counter_this_window and _card_hold_remaining == 0 \
			and _window_since_tick != -1 \
			and tick - _window_since_tick >= counter_delay_ticks:
		_card_slot = 3
		_card_hold_remaining = _card_hold_ticks_for(3)

	if _card_hold_remaining > 0:
		_card_hold_remaining -= 1
		input[InputCommand.KEY_CARD] = _card_slot
		# One pair of hands: while channeling a card, don't also charge the
		# fireball (both penalties would stack and neither throw lands well).
		return input

	# FIREBALL — charge casting: start a "button hold" on the interval; the
	# hold length cycles short/medium/long so release-fire shows level 1/2/3
	# charges (deterministic cycle, no RNG).
	if cast_interval_ticks > 0 and tick % cast_interval_ticks == 0:
		var hold: int = cast_hold_ticks + (_cast_cycle % 3) * hold_variation_ticks
		_cast_cycle += 1
		_cast_hold_remaining = maxi(_cast_hold_remaining, hold)
	if _cast_hold_remaining > 0:
		_cast_hold_remaining -= 1
		input[InputCommand.KEY_CAST] = 1

	return input


## Ticks to hold a card key: the caster's cost math + release margin for
## channeled ATTACK cards; a short TAP for the instant categories
## (cost_ticks_for_slot returns 0 for DEFENSE/COUNTER).
func _card_hold_ticks_for(slot: int) -> int:
	var cost_ticks: int = 0
	if _card_caster != null:
		cost_ticks = _card_caster.cost_ticks_for_slot(slot)
	if cost_ticks <= 0:
		return 3  # instant cast: a press-edge tap
	return cost_ticks + maxi(0, card_hold_margin_ticks)


## True when any live projectile is moving TOWARD this wizard within
## [param within_fp] down-court distance (the dodge scan's direction-sign
## test, parameterized).
func _hostile_ball_incoming(my_pos: SGFixedVector2, within_fp: int) -> bool:
	return _hostile_ball_count(my_pos, within_fp) > 0


## Count of live projectiles moving TOWARD this wizard within range — the
## reaction clock re-arms when this number GROWS (a fresh throw to notice).
func _hostile_ball_count(my_pos: SGFixedVector2, within_fp: int) -> int:
	if _container == null:
		return 0
	var count: int = 0
	for child in _container.get_children():
		if not child.has_method(&"get_velocity_y"):
			continue
		var dy: int = my_pos.y - child.get_global_fixed_position().y
		var vy: int = child.get_velocity_y()
		if vy != 0 and (vy > 0) == (dy > 0) and absi(dy) < within_fp:
			count += 1
	return count


# =====================================================================
# Internals (all int math)
# =====================================================================

## Dodge the nearest incoming fireball if one is aimed at us (only once the
## reaction delay has elapsed — has_reacted); otherwise shadow the target
## player's X. Returns -1 | 0 | 1.
func _decide_x(my_pos: SGFixedVector2, has_reacted: bool) -> int:
	var threat_x: int = 0
	var threat_found: bool = false
	var best_dist: int = _reaction_fp

	if _container != null and has_reacted:
		for child in _container.get_children():
			if not child.has_method(&"get_velocity_y"):
				continue
			var ball_pos: SGFixedVector2 = child.get_global_fixed_position()
			var dy: int = my_pos.y - ball_pos.y
			var vy: int = child.get_velocity_y()
			# Threat = moving TOWARD me: velocity Y sign matches the sign of
			# (my position - ball position). Our own just-cast balls move away.
			if vy == 0 or (vy > 0) != (dy > 0):
				continue
			var dist: int = absi(dy)
			if dist < best_dist:
				best_dist = dist
				threat_x = ball_pos.x
				threat_found = true

	if threat_found:
		var dx: int = threat_x - my_pos.x
		if absi(dx) < _dodge_fp:
			if dx == 0:
				# Dead-on shot: deterministic tie-break — dodge toward center.
				return -1 if my_pos.x > 0 else 1
			return -1 if dx > 0 else 1
		return 0  # Incoming but already clear of it: hold the lane.

	if _target != null:
		var tx: int = _target.get_global_fixed_position().x - my_pos.x
		if absi(tx) > _deadzone_fp:
			return 1 if tx > 0 else -1

	return 0


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
