## test_ice_shatter.gd — Phase 1: a fully-charged fireball shatters the Icey
## Retort frost wave and powers through; a normal fireball does NOT (headless).
##
## Spawns an enemy ice wave and a friendly fireball on a head-on course and
## checks the shatter gate by the fireball's shatters_ice flag.
##
## Run: <godot> --headless --path . -s res://tests/test_ice_shatter.gd
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


## Spawn an enemy frost wave at centre moving +Y (toward the player), source =
## opponent. Returns the wave node.
func _spawn_wave(projectiles: Node, opponent: Node) -> Node:
	var wave: Node = load("res://scenes/ice_wave.tscn").instantiate()
	projectiles.add_child(wave)
	wave.set_global_fixed_position(SGFixed.vector2(0, 0))
	wave.sync_to_physics_engine()
	wave.set_hit_source(opponent)
	wave.slow_ticks = 120
	wave.slow_scale_fp = SGFixed.from_float(0.3)
	wave.launch(0, SGFixed.div(SGFixed.from_float(300.0), SGFixed.from_int(60)), SGFixed.ONE)
	return wave


## Spawn a friendly fireball above the wave moving -Y into it, source = player.
func _spawn_fireball(projectiles: Node, player: Node, shatters: bool) -> Node:
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	projectiles.add_child(fb)
	fb.set_global_fixed_position(SGFixed.vector2(0, SGFixed.from_float(150.0)))
	fb.sync_to_physics_engine()
	fb.set_hit_source(player)
	fb.damage = 1
	fb.shatters_ice = shatters
	fb.launch(0, -SGFixed.div(SGFixed.from_float(600.0), SGFixed.from_int(60)), SGFixed.ONE)
	return fb


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	await _wait(0.3)

	var projectiles: Node = arena.get_node("Projectiles")
	var player: Node = arena.get_node("Player")
	var opponent: Node = arena.get_node("Opponent")
	for c in projectiles.get_children():
		c.queue_free()
	await _wait(0.1)

	# --- CONTROL: a NORMAL fireball must NOT shatter the wave -----------
	print("--- CONTROL: normal fireball passes through ---")
	var wave1: Node = _spawn_wave(projectiles, opponent)
	var fb1: Node = _spawn_fireball(projectiles, player, false)
	var wave1_ref: WeakRef = weakref(wave1)
	var fb1_ref: WeakRef = weakref(fb1)
	# Give them time to cross (they meet ~0.1 s in).
	await _wait(0.6)
	_ck(wave1_ref.get_ref() != null, "normal fireball did NOT shatter the wave (wave still alive)")
	for c in projectiles.get_children():
		c.queue_free()
	await _wait(0.2)

	# --- SHATTER: a MAX-CHARGE fireball breaks the wave + powers through -
	print("--- SHATTER: max-charge fireball breaks the wave ---")
	var wave2: Node = _spawn_wave(projectiles, opponent)
	var fb2: Node = _spawn_fireball(projectiles, player, true)
	var wave2_ref: WeakRef = weakref(wave2)
	var fb2_ref: WeakRef = weakref(fb2)
	var shattered: bool = await _await(func() -> bool: return wave2_ref.get_ref() == null, 3000)
	_ck(shattered, "max-charge fireball SHATTERED the ice wave (wave freed)")
	_ck(fb2_ref.get_ref() != null, "fireball POWERED THROUGH (not consumed by the shatter)")

	if _fails == 0:
		print("ICE SHATTER TEST: ALL PASS")
		quit(0)
	else:
		print("ICE SHATTER TEST: %d FAILURE(S)" % _fails)
		quit(1)
