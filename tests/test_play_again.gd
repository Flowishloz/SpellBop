## test_play_again.gd — proves the post-match PLAY AGAIN button restarts the
## match. Forces a 2-0 KO -> MATCH_OVER, asserts the button is shown, emits its
## pressed signal, and asserts the match is live again (ROUND_ACTIVE, scores 0).
## Run: godot --headless --path . -s res://tests/test_play_again.gd
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


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	ai.reaction_distance = 0.0
	ai.track_deadzone = 100000.0
	arena.post_round_seconds = 0.3
	# Sprint 20: collapse the death beat (the result overlay now waits it out).
	arena.death_sequence_seconds = 0.1
	arena.death_time_scale = 1.0
	root.add_child(arena)
	for i in 30:
		await process_frame

	# Round 1 KO, end the break, round 2 KO -> 2-0 match over.
	arena.get_node("Opponent/Health").apply_damage(5)
	await _wait(0.8)
	arena._post_round_deadline_msec = Time.get_ticks_msec()
	await _wait(0.8)
	arena.get_node("Opponent/Health").apply_damage(5)
	await _wait(1.2)

	var MATCH_OVER: int = 2
	var ROUND_ACTIVE: int = 0
	_ck(arena.match_state == MATCH_OVER, "match reached MATCH_OVER after 2-0")
	var overlay: Node = arena.get_node("MatchFlowOverlay")
	var btn: Button = overlay._play_again
	_ck(btn != null and btn.visible, "PLAY AGAIN button is shown on the match-end screen")

	# Press it.
	btn.pressed.emit()
	await _wait(0.4)
	_ck(arena.match_state == ROUND_ACTIVE, "PLAY AGAIN restarted the match (ROUND_ACTIVE)")
	_ck(arena.player_score == 0 and arena.opponent_score == 0, "scoreboard reset to 0-0 on rematch")

	if _fails == 0:
		print("PLAY AGAIN TEST: ALL PASS")
		quit(0)
	else:
		print("PLAY AGAIN TEST: %d FAILURE(S)" % _fails)
		quit(1)
