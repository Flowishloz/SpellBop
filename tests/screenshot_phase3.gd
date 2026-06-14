## screenshot_phase3.gd — visual smoke for Phase 3 UI: captures (1) the bold
## ROUND-1 call-out framed by horizontal lightning (fires on boot), and (2) the
## settled HUD — the enlarged bottom-right fireball button + the card hand with
## DEFENSE anchored at the bottom of the fan.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_phase3.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_scene = null  # keep the UI shots uncluttered
	root.add_child(arena)

	# (1) ROUND-1 lightning fires on boot — grab it mid-animation (~0.6 s).
	for i in 38:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/_screenshot_p3_round.png")

	# (2) Let the hand springs settle, then capture the HUD.
	for i in 150:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/_screenshot_p3_hud.png")

	print("PROBE: saved _screenshot_p3_round.png + _screenshot_p3_hud.png")
	quit(0)
