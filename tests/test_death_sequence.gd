## test_death_sequence.gd — Sprint 20 death/knockout sequence (headless).
##
## Boots the real arena, KOs a wizard directly, and proves the death beat:
##   SLOW-MO   — a KO dilates the world to death_time_scale (not normal speed).
##   SHADOW    — the eliminated wizard's floor shadow HIDES (no lingering disk).
##   VERDICT   — knockout_began fires (is_match_end distinguishes a round KO).
##   WAIT      — the result overlay (round_ended) is DELAYED through the beat, not
##               fired the instant the KO lands.
##   RESUME    — normal speed returns after death_sequence_seconds.
##
## Run: <godot> --headless --path . -s res://tests/test_death_sequence.gd
extends SceneTree

var _fails: int = 0


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


func _await(predicate: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call():
			return true
	return false


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	ai.reaction_distance = 0.0
	ai.track_deadzone = 100000.0
	arena.emerald_scene = null
	arena.death_sequence_seconds = 0.8   # short but clearly measurable
	arena.death_time_scale = 0.3
	arena.post_round_seconds = 0.5       # quick break so round 2 (revive) lands fast

	var ko_fired: Array = [false, false, false]  # [fired, is_match_end, player_won]
	# Mutate the array elements (captured by reference) — do NOT reassign the var
	# (GDScript lambdas capture locals by value, so a reassignment wouldn't escape).
	arena.knockout_began.connect(func(me: bool, pw: bool) -> void:
		ko_fired[0] = true
		ko_fired[1] = me
		ko_fired[2] = pw)
	var round_ended_fired: Array = [false]
	arena.round_ended.connect(func(_a: bool, _b: int, _c: int, _d: float) -> void:
		round_ended_fired[0] = true)
	root.add_child(arena)
	for i in 20:
		await process_frame

	# --- KO the OPPONENT: the player wins round 1 (not a match end yet) -----
	arena.get_node("Opponent/Health").apply_damage(5)
	await process_frame
	await process_frame

	_ck(Engine.time_scale < 0.5,
		"world dilated to death slow-mo on the KO (time_scale %.2f < 0.5)" % Engine.time_scale)
	_ck(ko_fired[0], "knockout_began fired on the KO")
	_ck(not ko_fired[1], "a round KO reports is_match_end = false")
	_ck(ko_fired[2], "player_won_round = true (the opponent was eliminated)")

	var shadow: Node = arena.get_node_or_null("Opponent/ShadowSprite")
	_ck(shadow != null and not shadow.visible,
		"the eliminated wizard's floor shadow is HIDDEN during the death beat")

	# The result overlay must WAIT — round_ended has NOT fired a beat after the KO.
	await _wait(0.3)
	_ck(not round_ended_fired[0],
		"result overlay WAITS through the death beat (round_ended not fired at 0.3 s)")

	# After the full beat the overlay raises (round_ended) and speed resumes.
	var ended: bool = await _await(func() -> bool: return round_ended_fired[0], 2500)
	_ck(ended, "round_ended fired AFTER the death beat (~0.8 s)")
	var resumed: bool = await _await(func() -> bool: return is_equal_approx(Engine.time_scale, 1.0), 2000)
	_ck(resumed, "normal speed resumed after the death beat")

	# The shadow comes back when the next round resets health.
	var revived: bool = await _await(func() -> bool: return shadow != null and shadow.visible, 3000)
	_ck(revived, "the shadow returns when the next round restores the wizard")

	if _fails == 0:
		print("DEATH SEQUENCE TEST: ALL PASS")
		quit(0)
	else:
		print("DEATH SEQUENCE TEST: %d FAILURE(S)" % _fails)
		quit(1)
