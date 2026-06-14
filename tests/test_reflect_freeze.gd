## test_reflect_freeze.gd — the reflected Icey Retort must ALWAYS freeze whoever
## it strikes (Creative Director: "sometimes it does not"). Two reproductions:
##   PART 1 — a FAST wave (near terminal velocity) aimed straight at a wizard,
##            hit_source = the OTHER wizard (a stand-in for a reflected wave):
##            it must connect and apply the frost slow, never tunnel past.
##   PART 2 — the FULL reflect path: a wave is captured + flung back by a defense
##            barrier, then must freeze the original thrower it returns to.
##
## Run: <godot> --headless --path . -s res://tests/test_reflect_freeze.gd
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


func _await(predicate: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call():
			return true
	return false


func _spawn_wave(container: Node, pos: SGFixedVector2, source: Node, vy_fp: int) -> Node:
	var wave: Node = load("res://scenes/ice_wave.tscn").instantiate()
	container.add_child(wave)
	wave.set_global_fixed_position(pos)
	wave.sync_to_physics_engine()
	wave.set_hit_source(source)
	wave.damage = 0
	wave.slow_ticks = 180
	wave.slow_scale_fp = SGFixed.from_float(0.3)
	wave.launch(0, vy_fp, SGFixed.ONE)
	return wave


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_scene = null
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	ai.reaction_distance = 0.0
	ai.track_deadzone = 100000.0
	root.add_child(arena)
	var player: Node = arena.get_node("Player")
	var opponent: Node = arena.get_node("Opponent")
	var player_move: Node = arena.get_node("Player/Movement")
	var projectiles: Node = arena.get_node("Projectiles")
	for i in 10:
		await process_frame

	# =================================================================
	# PART 1 — a FAST wave straight at the player must freeze it (anti-tunnel).
	# =================================================================
	print("--- PART 1: fast wave at terminal velocity ---")
	var ppos: SGFixedVector2 = player.get_global_fixed_position()
	# 300 units down-court of the player, flying back UP toward it (+Y), source =
	# the opponent so it is hostile to the player (like a reflected wave).
	var spawn: SGFixedVector2 = SGFixed.vector2(ppos.x, ppos.y - SGFixed.from_int(300))
	var fast_vy: int = SGFixed.div(SGFixed.from_float(2100.0), SGFixed.from_int(60))  # ~35 u/tick (near cap)
	_spawn_wave(projectiles, spawn, opponent, fast_vy)
	var froze1: bool = await _await(func() -> bool: return player_move.slow_ticks_remaining() > 0, 3000)
	_ck(froze1, "fast reflected-style wave FROZE the player (slow %d ticks)" % player_move.slow_ticks_remaining())

	# clear the field + the slow before PART 2.
	for c in projectiles.get_children():
		c.queue_free()
	player_move.halt()
	await process_frame
	await process_frame

	# =================================================================
	# PART 2 — full reflect: a defense barrier flings the wave back at its thrower.
	# =================================================================
	print("--- PART 2: barrier reflects the wave back at its thrower ---")
	# The PLAYER throws a counter wave down-court (-Y) toward the opponent; the
	# opponent's CardCaster deploys a defense barrier that captures + flings it back.
	var opp_caster: Node = arena.get_node("Opponent/CardCasterComponent")
	# Deploy the opponent's defense (slot 2) barrier in front of itself.
	opp_caster._resolve_defense(opp_caster._card_for_slot(2))
	await process_frame
	# Player's wave heading down-court (-Y) into the barrier, source = player.
	var opos: SGFixedVector2 = opponent.get_global_fixed_position()
	var down_vy: int = SGFixed.div(SGFixed.from_float(1600.0), SGFixed.from_int(60)) * -1
	_spawn_wave(projectiles, SGFixed.vector2(ppos.x, opos.y + SGFixed.from_int(300)), player, down_vy)
	# The thrower STEPS ASIDE (+330 units) after loosing it — the OLD random
	# ricochet would veer the returning wall off and miss. The fix flies it
	# straight and homes it onto the thrower, so it must still return and freeze.
	player.set_global_fixed_position(SGFixed.vector2(SGFixed.from_int(330), ppos.y))
	player.sync_to_physics_engine()
	# The barrier captures, holds, then flings it back UP toward the player — who
	# must freeze when it returns. Generous window (capture hold + return flight).
	var froze2: bool = await _await(func() -> bool: return player_move.slow_ticks_remaining() > 0, 6000)
	_ck(froze2, "barrier-reflected wave HOMED onto the stepped-aside thrower and FROZE it (slow %d ticks)" % player_move.slow_ticks_remaining())

	if _fails == 0:
		print("REFLECT FREEZE TEST: ALL PASS")
		quit(0)
	else:
		print("REFLECT FREEZE TEST: %d FAILURE(S)" % _fails)
		quit(1)
