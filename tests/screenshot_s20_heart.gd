## screenshot_s20_heart.gd — captures the heart-pop cue: an emerald is struck by a
## fireball and a red heart pops vertically out of it (the "you gained a life"
## cue), plus the green heal burst. NOT headless.
## Run: <godot> --path . -s res://tests/screenshot_s20_heart.gd
extends SceneTree


func _init() -> void:
	_run()


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_min_interval_seconds = 0.2
	arena.emerald_max_interval_seconds = 0.25
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	await _wait(0.6)  # let the emerald spawn
	var pickups: Array = get_nodes_in_group(&"pickups")
	if pickups.size() > 0:
		var em: Node = pickups[0]
		# Park it at a clear mid-court spot toward the player and freeze its drift.
		em.set_global_fixed_position(SGFixed.vector2(0, SGFixed.from_int(360)))
		em.sync_to_physics_engine()
		em.set(&"local_tick_driver_enabled", false)
		if em.has_method(&"emit_position"):
			em.emit_position()
		await _wait(0.3)
		# Strike it with a stationary fireball thrown by the player.
		var here: SGFixedVector2 = em.get_global_fixed_position()
		var fb: Node = load("res://scenes/fireball.tscn").instantiate()
		arena.get_node("Projectiles").add_child(fb)
		fb.set_global_fixed_position(here)
		fb.sync_to_physics_engine()
		fb.set_hit_source(arena.get_node("Player"))
		fb.damage = 1
		fb.launch(0, 0, SGFixed.ONE)
	# Grab the heart mid-arc (it pops up, then falls and despawns).
	await _wait(0.35)
	root.get_texture().get_image().save_png("res://tests/_screenshot_s20_heart.png")
	print("PROBE: saved _screenshot_s20_heart.png")
	quit(0)
