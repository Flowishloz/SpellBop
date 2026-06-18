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
## CURRENT BRAIN (Sprint 19 — independent opponent): dodge the nearest incoming
## fireball laterally; otherwise move on its OWN agenda — a deterministic patrol
## sweep across its court (NO mirroring of the player's X), lining up a straight
## down-court shot on a healing emerald while hurt; cast on a fixed tick interval
## (the caster's cooldown still gates it). EXPANSION SEAM: decide() is the single
## entry point — card play and strategic thinking extend its internals without
## touching the input pipeline.
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

## Deadzone, in sim units, around the AI's current target X before it bothers to
## step. Prevents jittery left/right oscillation.
@export var track_deadzone: float = 40.0

## INDEPENDENT MOVEMENT (Sprint 19, Phase 1 — Creative Director: the opponent must
## act on its OWN agenda, not shadow the player). With no incoming threat the brain
## patrols its court on a deterministic triangle sweep across ±patrol_amplitude
## instead of mirroring the player's X. No floats in the decision, no RNG.
@export var patrol_amplitude: float = 300.0

## Whole ticks for ONE full left->right->left patrol sweep (240 = 4 s @ 60 Hz).
@export var patrol_period_ticks: int = 240

## When hurt (HP below max), steer to line up a straight down-court shot on a
## healing emerald if one is on the field (its lane crosses the AI's own X).
@export var emerald_seek_enabled: bool = true

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

## DIFFICULTY — REACTIVE-BLOCK GATE: the DEFENSE (slot 2) "last-second block" only
## fires on ticks where ((tick / 20) % this) == 0, so a LARGER value blocks LESS
## often (the gate is open a smaller fraction of the time); 1 = always open (blocks
## every close ball). Set per difficulty tier in _ready. (Was hardcoded to 3 — the
## Sprint-19 "the AI was too hard" 1/3-open gate; now the Normal tier's value.)
@export var block_gate_modulo: int = 3

## DIFFICULTY — REACTIVE-BLOCK RANGE: down-court (Y) distance, in sim units, at
## which an incoming hostile ball is close enough to trigger the last-second block.
## Larger = blocks from further out (harder). Set per difficulty tier in _ready.
## (Was hardcoded to 350.0 in the _hostile_ball_incoming call.)
@export var block_range: float = 350.0

# --- Cached fixed-point values (computed once in _ready()) ---
var _reaction_fp: int = 0
var _dodge_fp: int = 0
var _deadzone_fp: int = 0
var _patrol_amp_fp: int = 0
var _block_range_fp: int = 0

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
var _health: Node
var _stack: Node


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "AIBrainComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	# DIFFICULTY: map GameSettings.ai_difficulty -> a tuning preset BEFORE the float
	# exports are cached to fixed-point below — that one-shot float->int conversion is
	# the ONLY place floats touch the brain; the per-tick decide() stays pure int.
	_apply_difficulty_preset()
	_container = get_node_or_null(projectile_container_path)
	_target = get_node_or_null(target_body_path) as SGCharacterBody2D
	_reaction_fp = SGFixed.from_float(maxf(0.0, reaction_distance))
	_dodge_fp = SGFixed.from_float(maxf(0.0, dodge_radius))
	_deadzone_fp = SGFixed.from_float(maxf(0.0, track_deadzone))
	_patrol_amp_fp = SGFixed.from_float(maxf(0.0, patrol_amplitude))
	_block_range_fp = SGFixed.from_float(maxf(0.0, block_range))
	# The brain sizes its card "button holds" from the caster's cost math
	# (reading static tuning, not sim state); it also reads its own health to
	# decide whether chasing a healing emerald is worthwhile.
	for child in _body.get_children():
		if child is CardCasterComponent:
			_card_caster = child
		elif child is HealthComponent:
			_health = child
	_stack = get_node_or_null(^"/root/TheStack")


## DIFFICULTY PRESET (Creative Director — the 3-tier Easy / Normal / Hard selector on the
## OFFLINE button). Reads GameSettings.ai_difficulty ONCE and rewrites the brain's tunables
## to that tier's preset. NORMAL (1) leaves every export UNTOUCHED — so it is EXACTLY the
## shipped tuning, which keeps the headless determinism sweep (whose GameSettings sits at the
## Normal default) bit-identical. EASY / HARD only ever apply in a live OFFLINE match (the AI
## is removed in netplay), so they never touch cross-peer sim. Scaling the WHOLE brain —
## reactions, vision, blocking, counters, offense — gives a meaningful Easy<->Hard spread (the
## CD's complaint was "the AI doesn't block much").
func _apply_difficulty_preset() -> void:
	var gs: Node = get_node_or_null(^"/root/GameSettings")
	var tier: int = 1
	if gs != null and "ai_difficulty" in gs:
		tier = clampi(int(gs.ai_difficulty), 0, 2)
	match tier:
		0:  # EASY — slow to notice, narrow vision, rarely blocks, gentle offense.
			reaction_delay_ticks = 45
			reaction_distance = 800.0
			dodge_radius = 120.0
			block_gate_modulo = 4
			block_range = 260.0
			counter_every_n_windows = 3
			cast_interval_ticks = 270
			card_interval_ticks = 840
			hold_variation_ticks = 8
		2:  # HARD — fast reactions, wide vision, blocks every close ball, aggressive.
			reaction_delay_ticks = 10
			reaction_distance = 1300.0
			dodge_radius = 175.0
			block_gate_modulo = 1
			block_range = 460.0
			counter_every_n_windows = 1
			cast_interval_ticks = 150
			card_interval_ticks = 480
			hold_variation_ticks = 18
		_:  # NORMAL (1) — leave the shipped @export tuning UNTOUCHED (keeps the
			# determinism sweep bit-identical; the headless suites run at this tier).
			pass


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

	var x_dir: int = _decide_x(my_pos, has_reacted, tick)
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
	var wall_window_open: bool = ((tick / 20) % maxi(1, block_gate_modulo)) == 0
	if card_interval_ticks > 0 and _card_hold_remaining == 0 and wall_window_open \
			and has_reacted \
			and _hostile_ball_incoming(my_pos, _block_range_fp):
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
## reaction delay has elapsed — has_reacted); otherwise move toward the brain's
## OWN independent target (patrol / emerald-seek), never the player's X.
## Returns -1 | 0 | 1.
func _decide_x(my_pos: SGFixedVector2, has_reacted: bool, tick: int) -> int:
	# 1) SURVIVAL FIRST: dodge the nearest incoming ball aimed at us.
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

	# 2) OWN AGENDA: step toward the brain's self-directed target X (never the
	# player's position). Move only past the deadzone so we don't jitter.
	var goal_x: int = _independent_target_x(my_pos, tick)
	var gdx: int = goal_x - my_pos.x
	if absi(gdx) > _deadzone_fp:
		return 1 if gdx > 0 else -1
	return 0


## The AI's self-directed target X (fixed-point), with NO reference to the
## player's position. Priority: line up a healing emerald while hurt, else patrol.
func _independent_target_x(_my_pos: SGFixedVector2, tick: int) -> int:
	if emerald_seek_enabled and _is_hurt():
		var emerald: Node = _find_emerald()
		if emerald != null:
			# A straight down-court throw from our X crosses center at our X, so
			# matching the emerald's X lines up the shot to heal.
			return emerald.get_global_fixed_position().x
	return _patrol_target_x(tick)


## Deterministic triangle-wave patrol across ±_patrol_amp_fp over
## patrol_period_ticks. Pure int math off the tick counter — identical on every
## peer, and completely independent of the player (no mirroring).
func _patrol_target_x(tick: int) -> int:
	var period: int = maxi(2, patrol_period_ticks)
	var half: int = period / 2
	var phase: int = tick % period
	var t: int = phase if phase < half else period - phase  # 0..half..0 ramp
	# Linear interp -amp -> +amp -> -amp (fixed-point; t/half is the 0..1 ramp).
	return -_patrol_amp_fp + (2 * _patrol_amp_fp * t) / maxi(1, half)


## True while this wizard is below max health (so a heal would help). Defensive:
## no HealthComponent resolved -> treat as not hurt (skip emerald seeking).
func _is_hurt() -> bool:
	if _health == null:
		return false
	return _health.get_health() < _health.max_health


## The healing emerald currently on the field (group "pickups"), or null. The
## group walk is scene-tree order — deterministic, like the wizards-group scans.
func _find_emerald() -> Node:
	for node in get_tree().get_nodes_in_group(&"pickups"):
		if node is SGFixedNode2D:
			return node
	return null


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
