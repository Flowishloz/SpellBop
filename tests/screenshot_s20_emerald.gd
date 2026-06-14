## screenshot_s20_emerald.gd — captures the Sprint 20 chaos-emerald gem: spawns an
## emerald, parks it at a clear mid-court spot toward the camera, and freezes its
## drift so the faceted gem reads in the shot.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_s20_emerald.gd
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
		# Park it mid-court, a little toward the player baseline, and freeze drift.
		em.set_global_fixed_position(SGFixed.vector2(0, SGFixed.from_int(380)))
		em.sync_to_physics_engine()
		em.set(&"local_tick_driver_enabled", false)
		if em.has_method(&"emit_position"):
			em.emit_position()
	await _wait(0.8)  # let the visual bridge settle + the gem spin a touch
	root.get_texture().get_image().save_png("res://tests/_screenshot_s20_emerald.png")
	print("PROBE: saved _screenshot_s20_emerald.png")
	quit(0)
