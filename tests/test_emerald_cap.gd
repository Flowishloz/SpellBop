## test_emerald_cap.gd — Sprint 20: at most emerald_max_per_match emeralds spawn
## across a match (Creative Director: limit the heal to 2 per game). One is ever on
## the field at a time, so claiming/clearing it lets the next spawn; once the match
## budget is spent, no more appear.
##
## Run: <godot> --headless --path . -s res://tests/test_emerald_cap.gd
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


func _await_emerald(timeout_ms: int) -> Node:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var nodes: Array = get_nodes_in_group(&"pickups")
		if nodes.size() > 0:
			return nodes[0]
	return null


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	# Fast cadence so the budget is exercised quickly; cap at 2 (the default).
	arena.emerald_min_interval_seconds = 0.2
	arena.emerald_max_interval_seconds = 0.25
	arena.emerald_max_per_match = 2
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)

	# #1 spawns; free it (simulating a claim) so the next can appear.
	var e1: Node = await _await_emerald(3000)
	_ck(e1 != null, "emerald #1 spawned")
	if e1 != null:
		e1.queue_free()
	await process_frame
	await process_frame

	# #2 spawns; free it too.
	var e2: Node = await _await_emerald(3000)
	_ck(e2 != null, "emerald #2 spawned after #1 was claimed")
	if e2 != null:
		e2.queue_free()
	await process_frame
	await process_frame

	# #3 must NEVER appear — the match budget (2) is spent.
	var e3: Node = await _await_emerald(1500)
	_ck(e3 == null, "emerald #3 did NOT spawn (cap = 2 per match)")
	_ck(int(arena._emeralds_spawned_this_match) == 2,
		"exactly 2 emeralds spawned this match (got %d)" % arena._emeralds_spawned_this_match)

	if _fails == 0:
		print("EMERALD CAP TEST: ALL PASS")
		quit(0)
	else:
		print("EMERALD CAP TEST: %d FAILURE(S)" % _fails)
		quit(1)
