## screenshot_p4_death.gd — captures the death-knockback fling clearly by KO-ing
## the PLAYER (closest to camera) and grabbing the arc a few frames in.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_p4_death.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_scene = null
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	for i in 50:
		await process_frame
	# KO the PLAYER (foreground) for a clear, large death fling.
	arena.get_node("Player/Health").apply_damage(5)
	for i in 8:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/_screenshot_p4_death.png")
	print("PROBE: saved _screenshot_p4_death.png (player fling)")
	quit(0)
