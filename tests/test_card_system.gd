## test_card_system.gd — Card framework end-to-end suite (headless).
##
## Boots the REAL match arena and plays the three baseline cards through the
## REAL input pipeline (a scripted brain feeds InputCommand dicts into the
## player's controller — the exact path human keys 8/9/0 take):
##   PHASE A — ATTACK "Arcane Bolt" STAGING: channel -> spell goes ON THE
##             STACK (countdown window opens, NO projectile yet) -> the bolt
##             fires only when the countdown releases it -> damage 2 lands.
##   PHASE B — DEFENSE "Verdant Bulwark": INSTANT deploy; the Window of
##             Affect CAPTURES the incoming ball on the wall, holds it
##             (anticipation), then reflects it back FASTER.
##   PHASE C — COUNTER "Frost Front": reactive lock in neutral; inside a
##             window it instantly looses the wide ice wave (2x speed,
##             0 damage) that SLOWS the struck wizard.
##   PHASE D — FIREBALL FULL CHARGE: release-fire at exactly 4x base speed.
##
## Run: <godot> --headless --path . -s res://tests/test_card_system.gd
extends SceneTree


## Deterministic scripted input source: the test pokes hold counters between
## frames; decide() turns them into InputCommand dicts exactly like fingers.
class ScriptedBrain extends AIBrainComponent:
	var hold_card_slot: int = 0
	var hold_card_ticks: int = 0
	var hold_cast_ticks: int = 0
	var move_dir: int = 0  # held alongside any action (aim/drift testing)

	func decide(_tick: int) -> Dictionary:
		var input: Dictionary = {}
		if move_dir != 0:
			input[InputCommand.KEY_X] = move_dir
		if hold_card_ticks > 0:
			hold_card_ticks -= 1
			input[InputCommand.KEY_CARD] = hold_card_slot
		elif hold_cast_ticks > 0:
			hold_cast_ticks -= 1
			input[InputCommand.KEY_CAST] = 1
		return input


var _failures: int = 0
var _stack_opens: int = 0
var _rejections: int = 0
var _staged: int = 0


func _check(ok: bool, label: String) -> void:
	if ok:
		print("PASS: ", label)
	else:
		print("FAIL: ", label)
		_failures += 1


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	var stack: Node = root.get_node_or_null("TheStack")
	var packed: PackedScene = load("res://scenes/match_arena.tscn")
	_check(stack != null and packed != null, "TheStack + match_arena load")
	if stack == null or packed == null:
		quit(1)
		return

	var arena: Node = packed.instantiate()
	# Isolate the card/charge mechanics from the Phase-1 STACK WINNER reward: a
	# 1.0x multiplier makes the next-throw boost a no-op (its own coverage lives
	# in tests/test_stack_resolution.gd). Set BEFORE add_child so _ready caches it.
	arena.stack_winner_speed_multiplier = 1.0

	# Neutralize the REAL AI completely (cast_interval/card_interval <= 0
	# disables fireballs and ALL card play incl. reactive walls/counters).
	var ai_brain: Node = arena.get_node("Opponent/AIBrain")
	ai_brain.cast_interval_ticks = 0
	ai_brain.card_interval_ticks = 0
	ai_brain.counter_enabled = false
	ai_brain.reaction_distance = 0.0
	ai_brain.track_deadzone = 100000.0

	# Possess the PLAYER with the scripted brain (attached before _ready so
	# PlayerController adopts it as its input source).
	var brain := ScriptedBrain.new()
	brain.name = "ScriptedBrain"
	brain.cast_interval_ticks = 0
	brain.card_interval_ticks = 0
	brain.counter_enabled = false
	arena.get_node("Player").add_child(brain)

	root.add_child(arena)
	await process_frame

	stack.stack_opened.connect(func(_d: float) -> void: _stack_opens += 1)

	var projectiles: Node = arena.get_node("Projectiles")
	var opponent: Node = arena.get_node("Opponent")
	var opponent_health: Node = arena.get_node("Opponent/Health")
	var opponent_movement: Node = arena.get_node("Opponent/Movement")
	var card_caster: Node = arena.get_node("Player/CardCasterComponent")
	card_caster.card_rejected.connect(func(_c: Resource) -> void: _rejections += 1)
	card_caster.spell_staged.connect(func(_c: Resource) -> void: _staged += 1)

	# =================================================================
	# PHASE A — ATTACK card: STAGE first, fire at countdown release.
	# =================================================================
	print("--- PHASE A: ATTACK staging ---")
	brain.hold_card_slot = 1
	brain.hold_card_ticks = 75  # cost 2 = 60 ticks channel; stages at 60

	var got_staged: bool = await _await_condition(func() -> bool: return _staged > 0, 4000)
	_check(got_staged, "A: channel completed -> spell STAGED on the stack")
	_check(_stack_opens == 1, "A: staging opened the Stack window (opens=%d)" % _stack_opens)
	_check(projectiles.get_child_count() == 0, "A: NO projectile during the countdown (the spell waits on the stack)")
	await process_frame
	_check(is_equal_approx(Engine.time_scale, 0.1), "A: world at 10%% slow-mo during the countdown (got %.3f)" % Engine.time_scale)

	# The 15 stage ticks at 10% speed = ~2.5 real seconds until release.
	var bolt: Node = await _await_first_child(projectiles, 6000)
	_check(bolt != null, "A: countdown released the bolt (projectile fired AFTER staging)")
	if bolt != null:
		_check(bolt.get("damage") == 2, "A: bolt carries damage 2 (got %s)" % str(bolt.get("damage")))

	var hp_before: int = opponent_health.get_health()
	var damaged: bool = await _await_condition(
			func() -> bool: return opponent_health.get_health() < hp_before, 6000)
	_check(damaged, "A: released bolt damaged the opponent (hp %d -> %d)" % [hp_before, opponent_health.get_health()])
	_check(opponent_health.get_health() == hp_before - 2, "A: exactly 2 damage applied")
	await _await_condition(func() -> bool: return projectiles.get_child_count() == 0, 5000)
	stack.close_window()

	# =================================================================
	# PHASE B — DEFENSE: instant deploy + WOA capture/hold/reflect.
	# =================================================================
	print("--- PHASE B: DEFENSE instant + WOA capture ---")
	# Hostile ball first: mid-court, flying at the player at 500 u/s.
	var hostile: Node = load("res://scenes/fireball.tscn").instantiate()
	projectiles.add_child(hostile)
	hostile.set_global_fixed_position(SGFixed.vector2(0, 0))
	hostile.sync_to_physics_engine()
	hostile.set_hit_source(opponent)
	var vy_in: int = SGFixed.div(SGFixed.from_float(500.0), SGFixed.from_int(60))
	hostile.launch(0, vy_in, SGFixed.ONE)

	# Wait until it's CLOSE (y > 400 sim units), then tap the wall — a
	# decent-WOA block.
	var got_close: bool = await _await_condition(func() -> bool:
		return is_instance_valid(hostile) and hostile.get_global_fixed_position().y > 26214400, 5000)
	_check(got_close, "B: hostile ball reached the block window")
	var opens_before_defense: int = _stack_opens
	# SHIELD PLACEMENT PROOF (Creative Director report): tap the wall WHILE
	# HOLDING a movement direction — the barrier must still land at the
	# caster's exact X (directional input never aims the shield).
	brain.move_dir = 1
	brain.hold_card_slot = 2
	brain.hold_card_ticks = 3  # instant cast: a tap

	var barrier: Node = await _await_condition_node(func() -> Node:
		for child in projectiles.get_children():
			if child.has_method(&"deploy"):
				return child
		return null, 2000)
	brain.move_dir = 0
	_check(barrier != null, "B: barrier deployed INSTANTLY on the tap")
	_check(_stack_opens == opens_before_defense, "B: instant defense did NOT open the Stack")
	if barrier != null:
		_check(barrier.collision_layer == 8, "B: ONE-WAY wall on the P1-barrier layer (got %d)" % barrier.collision_layer)
		# Exact placement: within one tick-step of the moving caster's X
		# (the poll runs a frame after the deploy tick).
		var player_body: Node = arena.get_node("Player")
		var dx: int = absi(barrier.get_global_fixed_position().x - player_body.get_global_fixed_position().x)
		_check(dx < 1966080, "B: wall centered on the caster despite held input (|dx|=%.1f units)" % (dx / 65536.0))

	# Capture: the ball freezes on the wall (velocity 0), then releases
	# REVERSED and FASTER (reflect multiplier > 1 at this WOA).
	var captured: bool = await _await_condition(func() -> bool:
		return is_instance_valid(hostile) and hostile.get_velocity_y() == 0, 4000)
	_check(captured, "B: wall CAPTURED the ball (frozen for the anticipation hold)")
	var released: bool = await _await_condition(func() -> bool:
		return is_instance_valid(hostile) and hostile.get_velocity_y() < 0, 4000)
	_check(released, "B: hold released the ball back down-court")
	if released:
		_check(absi(hostile.get_velocity_y()) > vy_in,
				"B: reflected FASTER than it arrived (|%d| > %d — WOA reflect multiplier)" % [hostile.get_velocity_y(), vy_in])
	var barrier_ref: WeakRef = weakref(barrier)
	var barrier_gone: bool = await _await_condition(func() -> bool: return barrier_ref.get_ref() == null, 6000)
	_check(barrier_gone, "B: barrier expired on wall_lifetime")
	await _await_condition(func() -> bool: return projectiles.get_child_count() == 0, 6000)

	# =================================================================
	# PHASE C — COUNTER: reactive lock, then the instant frost wave.
	# =================================================================
	print("--- PHASE C: COUNTER frost wave ---")
	# C1: neutral play — the counter must refuse.
	brain.hold_card_slot = 3
	brain.hold_card_ticks = 5
	var rejected: bool = await _await_condition(func() -> bool: return _rejections > 0, 3000)
	_check(rejected, "C: reactive-only counter REJECTED in neutral play")
	_check(projectiles.get_child_count() == 0, "C: rejected counter spawned nothing")

	# RELEASE GAP: instant casts fire on the PRESS EDGE. The C1 hold must
	# fully release (a few zero-input ticks) before C2's tap counts as a
	# fresh press — exactly like a human letting go of the key.
	brain.hold_card_ticks = 0
	await process_frame
	await process_frame
	await process_frame

	# C2: inside a window the counter SLAPS ONTO THE STACK (staged, timer
	# resets) and its frost wave releases only when the stack resolves.
	# PACE PIN: run this window at 1.0x so the suite stays fast (Phase A
	# already proved the 0.1 dilation; the lock keys off window STATE).
	stack.stack_time_scale = 1.0
	stack.open_window(2.0)
	# Sprint 22 Phase 2: TheStack is presentation-only now — the SIM-side StackResolver
	# is what the counter's reactive-lock reads. A real enemy stage would arm it; here we
	# arm it directly to fake "an enemy spell is on the stack" (2.0 s window at 1.0x =
	# 120 ticks) so the player's counter is allowed to slap.
	var resolver: Node = arena.get_node("StackResolver")
	resolver.arm(int(ceil(2.0 * 60.0 * stack.stack_time_scale)))
	var opens_with_window: int = _stack_opens
	var staged_before: int = _staged
	brain.hold_card_slot = 3
	brain.hold_card_ticks = 5

	var slapped: bool = await _await_condition(func() -> bool: return _staged > staged_before, 3000)
	_check(slapped, "C: counter SLAPPED onto the stack (staged, not fired)")
	_check(projectiles.get_child_count() == 0, "C: no wave during the countdown — it waits on the stack")
	_check(_stack_opens == opens_with_window, "C: the slap did NOT restart the shared clock (opens=%d)" % _stack_opens)

	# The ORIGINAL countdown (2.0 s) expires -> stack resolves -> wave.
	var wave: Node = await _await_first_child(projectiles, 5000)
	_check(wave != null, "C: stack resolution released the frost wave")
	if wave != null:
		_check(wave.get("damage") == 0, "C: wave deals NO damage (got %s)" % str(wave.get("damage")))
		_check(int(wave.get("slow_ticks")) == 180, "C: wave carries the 3 s slow (180 ticks, got %s)" % str(wave.get("slow_ticks")))
		# 2x a default fireball: 1600 u/s, fired down-court (-Y for P1).
		var want_vy: int = -SGFixed.div(SGFixed.from_float(1600.0), SGFixed.from_int(60))
		_check(wave.get_velocity_y() == want_vy, "C: wave speed EXACTLY 1600 u/s (vy=%d want %d)" % [wave.get_velocity_y(), want_vy])

	var hp_before_wave: int = opponent_health.get_health()
	var slowed: bool = await _await_condition(func() -> bool:
		return opponent_movement.slow_ticks_remaining() > 0, 5000)
	_check(slowed, "C: struck wizard is FROZEN-SLOWED (%d ticks remaining)" % opponent_movement.slow_ticks_remaining())
	_check(opponent_health.get_health() == hp_before_wave, "C: frost dealt zero damage")
	stack.close_window()
	stack.stack_time_scale = 0.1
	await _await_condition(func() -> bool: return projectiles.get_child_count() == 0, 5000)

	# =================================================================
	# PHASE D — Fireball FULL CHARGE: release-fire at exactly 4x.
	# =================================================================
	print("--- PHASE D: full-charge release-fire ---")
	var opens_final: int = _stack_opens
	brain.hold_cast_ticks = 95  # cast 30 + boost range 60 = capped at 90
	var charged: Node = await _await_first_child(projectiles, 5000)
	_check(charged != null, "D: full-charge release fired a ball")
	if charged != null:
		var per_tick: int = SGFixed.div(SGFixed.from_float(800.0), SGFixed.from_int(60))
		var want: int = -SGFixed.mul(per_tick, SGFixed.from_float(4.0))
		_check(charged.get_velocity_y() == want,
				"D: velocity EXACTLY 4x base (vy=%d, want %d)" % [charged.get_velocity_y(), want])
	_check(_stack_opens == opens_final, "D: base fireball never opens the Stack")
	await _await_condition(func() -> bool: return projectiles.get_child_count() == 0, 6000)

	if _failures == 0:
		print("CARD SYSTEM TEST: ALL PASS")
	else:
		print("CARD SYSTEM TEST: %d FAILURES" % _failures)
	quit(_failures)


# --- helpers ---------------------------------------------------------

func _await_first_child(container: Node, timeout_ms: int) -> Node:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if container.get_child_count() > 0:
			return container.get_child(0)
	return null


func _await_condition(predicate: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call():
			return true
	return false


func _await_condition_node(provider: Callable, timeout_ms: int) -> Node:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var node: Node = provider.call()
		if node != null:
			return node
	return null
