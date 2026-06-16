## test_round_flow.gd — Best-of-3 round system (headless).
##
## Boots the REAL arena with both AIs neutralized and drives KOs directly
## through the deterministic damage API:
##   KO #1 -> round ends (score 1-0), sim PARKED, projectiles cleared,
##            post-round break runs (shortened for the suite) -> next round
##            starts with healths/positions/casters reset.
##   KO #2 -> match over (2-0), victory state, sim stays parked.
##   Rematch input -> scores reset, round 1 restarts.
##
## Run: <godot> --headless --path . -s res://tests/test_round_flow.gd
extends SceneTree

var _failures: int = 0
var _round_started_count: int = 0
var _last_round_number: int = 0
var _round_ended_count: int = 0
var _match_ended: bool = false
var _match_winner_player: bool = false


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
	var packed: PackedScene = load("res://scenes/match_arena.tscn")
	var arena: Node = packed.instantiate()

	var ai_brain: Node = arena.get_node("Opponent/AIBrain")
	ai_brain.cast_interval_ticks = 0
	ai_brain.card_interval_ticks = 0
	ai_brain.counter_enabled = false
	ai_brain.reaction_distance = 0.0
	ai_brain.track_deadzone = 100000.0

	arena.post_round_seconds = 1.0  # shorten the 15 s break for the suite
	# Sprint 20: skip the dramatic death beat for this deterministic flow test —
	# round_ended/match_ended now fire AFTER death_sequence_seconds, so collapse it
	# and drop the slow-mo (the death sequence is verified by its own probe).
	arena.death_sequence_seconds = 0.1
	arena.death_time_scale = 1.0
	arena.round_intro_seconds = 0.0  # no round-intro freeze — assert the driver resumes immediately
	root.add_child(arena)
	await process_frame

	var player: Node = arena.get_node("Player")
	var opponent: Node = arena.get_node("Opponent")
	var player_health: Node = arena.get_node("Player/Health")
	var opponent_health: Node = arena.get_node("Opponent/Health")

	arena.round_started.connect(func(n: int) -> void:
		_round_started_count += 1
		_last_round_number = n)
	arena.round_ended.connect(func(_pw: bool, _ps: int, _os: int, _bs: float) -> void:
		_round_ended_count += 1)
	arena.match_ended.connect(func(pw: bool) -> void:
		_match_ended = true
		_match_winner_player = pw)

	_check(player_health.max_health == 5, "health pool is 5 points (got %d)" % player_health.max_health)

	# --- KO #1: opponent down -> round ends, sim parks ----------------
	# round_ended now fires AFTER the (collapsed) death beat — wait for it.
	opponent_health.apply_damage(5)
	var ended1: bool = await _await_condition(func() -> bool: return _round_ended_count == 1, 2000)
	_check(ended1, "KO ended round 1 (round_ended fired after the death beat)")
	_check(arena.player_score == 1 and arena.opponent_score == 0, "score 1-0 (got %d-%d)" % [arena.player_score, arena.opponent_score])
	_check(player.local_tick_driver_enabled == false, "sim PARKED for the post-round break")

	# --- break elapses -> round 2 starts fully reset -------------------
	var restarted: bool = await _await_condition(func() -> bool: return _last_round_number == 2, 4000)
	_check(restarted, "post-round break elapsed -> round 2 started")
	_check(player.local_tick_driver_enabled == true, "sim RESUMED for round 2")
	_check(opponent_health.get_health() == 5 and player_health.get_health() == 5, "healths reset to 5/5")
	_check(player.get_global_fixed_position().y == 57671680, "player back on the spawn baseline")
	_check(opponent.get_global_fixed_position().y == -57671680, "opponent back on the spawn baseline")

	# --- KO #2: match over ---------------------------------------------
	opponent_health.apply_damage(5)
	var ended2: bool = await _await_condition(func() -> bool: return _match_ended, 2000)
	_check(ended2 and _match_winner_player, "second KO ended the MATCH for the player (2-0)")
	_check(arena.match_state == arena.MatchState.MATCH_OVER, "match state is MATCH_OVER")
	_check(player.local_tick_driver_enabled == false, "sim parked on the victory screen")

	# --- rematch input --------------------------------------------------
	Input.action_press("cast_spell")
	await process_frame
	await process_frame
	Input.action_release("cast_spell")
	var rematched: bool = await _await_condition(func() -> bool:
		return _last_round_number == 1 and arena.player_score == 0, 3000)
	_check(rematched, "rematch input reset scores and restarted at round 1")
	_check(player.local_tick_driver_enabled == true, "sim running again after rematch")

	if _failures == 0:
		print("ROUND FLOW TEST: ALL PASS")
	else:
		print("ROUND FLOW TEST: %d FAILURES" % _failures)
	quit(_failures)


func _await_condition(predicate: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call():
			return true
	return false
