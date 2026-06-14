## screenshot_s20_death.gd — captures the Sprint 20 death sequence: a match-ending
## KO of the opponent → VICTORY verdict (yellow, high), the opponent flung off the
## arena in slow-mo, the bigger explosion, and the death cam zoomed on the sprite.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_s20_death.gd
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
	arena.emerald_scene = null
	arena.rounds_to_win = 1            # first KO ends the match -> VICTORY verdict
	arena.death_sequence_seconds = 3.0  # long beat so we can grab it mid-fling
	arena.death_time_scale = 0.3
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	for i in 40:
		await process_frame
	# KO the OPPONENT: the player WINS -> VICTORY heading + the opponent is flung.
	arena.get_node("Opponent/Health").apply_damage(5)
	# Grab it ~1.8 s in — after the 1.5 s dolly zoom has settled on the sprite.
	await _wait(1.8)
	root.get_texture().get_image().save_png("res://tests/_screenshot_s20_death.png")
	print("PROBE: saved _screenshot_s20_death.png")
	quit(0)
