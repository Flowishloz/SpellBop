## test_stack_resolution.gd — Phase 1 stack-resolution rules (headless).
##
## Boots the REAL match arena and drives the player with a scripted brain to
## prove the two new rules:
##   STAGGER — two spells on the stack resolve ONE AT A TIME, ~0.2 s apart (not
##             all in one frame), and the world stays dilated until the last
##             spell, THEN speed ramps back to 1.0.
##   WINNER  — the player who placed the NEWEST spell on the stack (last
##             responder, always) gets a 1.5x speed boost on their NEXT throw.
##
## Run: <godot> --headless --path . -s res://tests/test_stack_resolution.gd
extends SceneTree

var _fails: int = 0


## Scripted input source (same shape as test_card_system's): the test pokes hold
## counters between frames; decide() turns them into InputCommand dicts.
class ScriptedBrain extends AIBrainComponent:
	var hold_card_slot: int = 0
	var hold_card_ticks: int = 0

	func decide(_tick: int) -> Dictionary:
		var input: Dictionary = {}
		if hold_card_ticks > 0:
			hold_card_ticks -= 1
			input[InputCommand.KEY_CARD] = hold_card_slot
		return input


func _init() -> void:
	_run()


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## Wait until the container holds at least [param n] children, return the msec it
## happened (or -1 on timeout).
func _await_count(container: Node, n: int, timeout_ms: int) -> int:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if container.get_child_count() >= n:
			return Time.get_ticks_msec()
	return -1


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	var stack: Node = root.get_node_or_null("TheStack")

	# Silence the real AI; possess the player with the scripted brain.
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	ai.reaction_distance = 0.0
	ai.track_deadzone = 100000.0
	var brain := ScriptedBrain.new()
	brain.name = "ScriptedBrain"
	brain.cast_interval_ticks = 0
	brain.card_interval_ticks = 0
	brain.counter_enabled = false
	arena.get_node("Player").add_child(brain)
	root.add_child(arena)

	var projectiles: Node = arena.get_node("Projectiles")
	var player: Node = arena.get_node("Player")

	# =================================================================
	# PART 1 — STAGGER + WINNER (pin time_scale 1.0 for reliable staging;
	# the 0.2 s release gap is a wall-clock timer, independent of dilation).
	# =================================================================
	print("--- PART 1: staggered release + winner reward ---")
	stack.stack_time_scale = 1.0
	stack.default_window_seconds = 0.9
	await _wait(0.4)

	# Stage an ATTACK (slot 1) -> the window opens.
	brain.hold_card_slot = 1
	brain.hold_card_ticks = 6
	await _wait(0.25)
	_ck(stack.state == stack.State.STACK_WINDOW, "attack staging opened the stack window")

	# Release, then SLAP a COUNTER (slot 3) onto the same window -> 2 on the stack.
	brain.hold_card_ticks = 0
	await _wait(0.1)
	brain.hold_card_slot = 3
	brain.hold_card_ticks = 6
	await _wait(0.1)

	# The shared 0.9 s window (from the attack) expires -> staggered resolution.
	var t_first: int = await _await_count(projectiles, 1, 4000)
	# THE STACK DISPLAY must peel ONE card on the first resolution (MTG-Arena
	# style), not fly the whole pile away at once — the real cause of the
	# "resolves simultaneously" report. Sampled the instant the 1st spell fires.
	var stack_hud: Node = arena.get_node_or_null("StackDisplayHUD")
	if stack_hud != null:
		var leaving: int = 0
		var staying: int = 0
		for e in stack_hud._entries:
			if e["leaving"]:
				leaving += 1
			else:
				staying += 1
		_ck(leaving == 1 and staying >= 1,
			"stack DISPLAY peeled ONE card on the first resolution (leaving=%d, staying=%d) — not all at once" % [leaving, staying])
	var t_second: int = await _await_count(projectiles, 2, 4000)
	_ck(t_first > 0, "first staged spell resolved")
	_ck(t_second > 0, "second staged spell resolved (both came off the stack)")
	if t_first > 0 and t_second > 0:
		var gap_ms: int = t_second - t_first
		_ck(gap_ms >= 120, "spells resolved ONE AT A TIME (gap %d ms >= 120, not simultaneous)" % gap_ms)
		# VISIBLE SEPARATION (round-2 fix): timing alone isn't enough — at the
		# resolve slow-mo the FIRST spell must already be well down-court when the
		# SECOND launches, or they cluster near the spawn and read as simultaneous.
		if projectiles.get_child_count() >= 2:
			var p0: SGFixedVector2 = projectiles.get_child(0).get_global_fixed_position()
			var p1: SGFixedVector2 = projectiles.get_child(1).get_global_fixed_position()
			var gap_units: float = absi(p0.y - p1.y) / 65536.0
			_ck(gap_units > 200.0,
				"first spell %.0f units down-court when the second launches (>200 = visibly separated)" % gap_units)

	# WINNER = last responder = the COUNTER (slot 3), the player's -> the player
	# banks a 1.5x boost on its NEXT throw. Granted AFTER the stack fully resolves
	# (the longer round-2 stagger + post-resolve beat pushes this out — wait it out).
	await _wait(1.2)
	var boost: int = player.consume_speed_boost() if player.has_method(&"consume_speed_boost") else 0
	_ck(boost == SGFixed.from_float(1.5), "stack winner (player) banked a 1.5x next-throw boost (got %d, want %d)" % [boost, SGFixed.from_float(1.5)])

	# Let the field clear before PART 2.
	await _wait(0.4)
	for c in projectiles.get_children():
		c.queue_free()
	await _wait(0.3)

	# =================================================================
	# PART 2 — SLOW-MO HELD until resolution, THEN resume to 1.0.
	# =================================================================
	print("--- PART 2: slow-mo held through resolution, then resume ---")
	stack.stack_time_scale = 0.1
	stack.default_window_seconds = 0.8
	# Slot 1 is still on its 4 s cooldown from PART 1 — clear the player's card
	# state so the fresh attack actually stages (and opens the window).
	var card_caster: Node = player.get_node_or_null("CardCasterComponent")
	if card_caster != null:
		card_caster.reset_cast_state()
	await _wait(0.2)

	brain.hold_card_slot = 1
	brain.hold_card_ticks = 8
	# Window opens -> world dilates. Sample a moment after it opens.
	var dilated: bool = await _await_dilated(0.15, 3000)
	_ck(dilated, "world dilated to slow-mo while the spell sits on the stack (<= 0.15)")

	# Wait out the window + the staggered resolution + the resume ramp.
	var resumed: bool = false
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if is_equal_approx(Engine.time_scale, 1.0):
			resumed = true
			break
	_ck(resumed, "normal speed resumed (1.0) after the final spell resolved")

	if _fails == 0:
		print("STACK RESOLUTION TEST: ALL PASS")
		quit(0)
	else:
		print("STACK RESOLUTION TEST: %d FAILURE(S)" % _fails)
		quit(1)


## True once Engine.time_scale drops to/below [param threshold] within the timeout.
func _await_dilated(threshold: float, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if Engine.time_scale <= threshold:
			return true
	return false
