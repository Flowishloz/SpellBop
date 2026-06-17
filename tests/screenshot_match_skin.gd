## screenshot_match_skin.gd — boots match_arena with a chosen equipped skin (set IN MEMORY, so the
## user's user://settings.cfg is untouched) and screenshots it, to verify the LOCAL player's wizard
## wears the equipped cosmetic skin in-match (the equip->match gap #4 fix). NOT headless — needs a
## real window / GPU.
## Run: <godot> --path . -s res://tests/screenshot_match_skin.gd ++ space_wizard
extends SceneTree

const OUT := "res://tests/_screenshot.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	# Positional args: [player_skin] [opponent_skin]. Opponent override is offline-only (debug toggle).
	var args := OS.get_cmdline_user_args()
	var player_id := String(args[0]) if args.size() > 0 else "space_wizard"
	var gs: Node = root.get_node_or_null("GameSettings")
	if gs != null:
		gs.set(&"equipped_skin", StringName(player_id))
		if args.size() > 1:
			gs.set(&"opponent_skin", StringName(args[1]))
	root.add_child(load("res://scenes/match_arena.tscn").instantiate())
	for i in 90:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: match player='", player_id, "' -> ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
