## test_emerald.gd — Phase 1 healing emerald (headless).
##
## Speeds the spawn cadence right down, then proves:
##   SPAWN  — an emerald appears near the arena centre and is in the "pickups"
##            group (so the AI can find it).
##   DRIFT  — its sim position changes over a few ticks (it wanders).
##   HEAL   — striking it with a projectile grants the THROWER a life back and
##            frees both the emerald and the ball.
##
## Run: <godot> --headless --path . -s res://tests/test_emerald.gd
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
	# Fast cadence: set BEFORE add_child so _ready's reseed picks it up.
	arena.emerald_min_interval_seconds = 0.4
	arena.emerald_max_interval_seconds = 0.5
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)

	var player: Node = arena.get_node("Player")
	var player_health: Node = arena.get_node("Player/Health")
	var projectiles: Node = arena.get_node("Projectiles")

	# --- SPAWN ----------------------------------------------------------
	print("--- SPAWN ---")
	var emerald: Node = await _await_emerald(4000)
	_ck(emerald != null, "an emerald spawned and joined the 'pickups' group")
	if emerald == null:
		print("EMERALD TEST: %d FAILURE(S)" % (_fails + 1))
		quit(1)
		return
	# Freeze the spawner so it never REFRESHES (frees + respawns) our captured
	# emerald mid-test — the rest of the suite needs a stable instance.
	arena.emerald_scene = null
	var p0: SGFixedVector2 = emerald.get_global_fixed_position()
	_ck(absi(p0.x) < SGFixed.from_float(320.0) and absi(p0.y) < SGFixed.from_float(320.0),
		"emerald spawned near the arena centre (%.0f, %.0f units)" % [p0.x / 65536.0, p0.y / 65536.0])

	# --- DRIFT ----------------------------------------------------------
	print("--- DRIFT ---")
	await _wait(0.6)
	var p1: SGFixedVector2 = emerald.get_global_fixed_position()
	_ck(absi(p1.x - p0.x) + absi(p1.y - p0.y) > 0, "emerald DRIFTED (position changed)")

	# --- HEAL -----------------------------------------------------------
	print("--- HEAL ---")
	player_health.apply_damage(2)  # 5 -> 3 so a heal can land
	_ck(player_health.get_health() == 3, "player damaged to 3 HP before the pickup")

	# Spawn a stationary fireball ON the emerald, thrown by the player.
	var here: SGFixedVector2 = emerald.get_global_fixed_position()
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	projectiles.add_child(fb)
	fb.set_global_fixed_position(here)
	fb.sync_to_physics_engine()
	fb.set_hit_source(player)
	fb.damage = 1
	fb.launch(0, 0, SGFixed.ONE)
	var em_ref: WeakRef = weakref(emerald)
	var fb_ref: WeakRef = weakref(fb)

	var healed: bool = false
	var deadline: int = Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if player_health.get_health() > 3:
			healed = true
			break
	_ck(healed, "striking the emerald HEALED the thrower (HP %d, was 3)" % player_health.get_health())
	_ck(player_health.get_health() == 4, "exactly +1 life granted")
	await _wait(0.2)
	_ck(em_ref.get_ref() == null, "emerald was consumed (freed) on the strike")
	_ck(fb_ref.get_ref() == null, "the striking projectile was consumed too")

	if _fails == 0:
		print("EMERALD TEST: ALL PASS")
		quit(0)
	else:
		print("EMERALD TEST: %d FAILURE(S)" % _fails)
		quit(1)
