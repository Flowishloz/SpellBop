## screenshot_s20_death_lose.gd — the LOSS case of the knockout: the PLAYER is
## eliminated → DEFEAT (red) verdict + the gentler 20% death-cam zoom (0.80).
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_s20_death_lose.gd
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
	arena.rounds_to_win = 1              # first KO ends the match -> DEFEAT verdict
	arena.death_sequence_seconds = 3.0
	arena.death_time_scale = 0.3
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	for i in 40:
		await process_frame
	# KO the PLAYER: the player LOSES -> DEFEAT heading + the 20% (gentler) zoom.
	arena.get_node("Player/Health").apply_damage(5)
	await _wait(0.9)
	root.get_texture().get_image().save_png("res://tests/_screenshot_s20_death_lose.png")
	print("PROBE: saved _screenshot_s20_death_lose.png")
	quit(0)
