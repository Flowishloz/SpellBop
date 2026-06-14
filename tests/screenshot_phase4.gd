## screenshot_phase4.gd — visual smoke for Phase 4 graphics: (1) the 80s
## space/planet main-menu backdrop, (2) the glowing arena borders, (3) the
## death-knockback fling on a lethal hit.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_phase4.gd
extends SceneTree


func _init() -> void:
	_run()


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _run() -> void:
	await process_frame

	# (1) HOME SCREEN — 80s space + planet backdrop.
	var home: Node = load("res://scenes/home_screen.tscn").instantiate()
	root.add_child(home)
	for i in 70:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/_screenshot_p4_home.png")
	home.queue_free()
	await _wait(0.4)

	# (2) ARENA — glowing perimeter borders.
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_scene = null
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	for i in 70:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/_screenshot_p4_arena.png")

	# (3) DEATH — KO the opponent, capture the backward fling mid-arc.
	arena.get_node("Opponent/Health").apply_damage(5)
	for i in 16:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/_screenshot_p4_death.png")

	print("PROBE: saved _screenshot_p4_home.png + _arena.png + _death.png")
	quit(0)
