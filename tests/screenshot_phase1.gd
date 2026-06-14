## screenshot_phase1.gd — visual smoke for Phase 1: boots the arena, forces a
## healing emerald to spawn near centre, and saves a frame so the emerald render
## + the dash-free HUD (cast button only, bottom-right) can be eyeballed.
## NOT headless (needs a window/GPU). Run: <godot> --path . -s res://tests/screenshot_phase1.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_min_interval_seconds = 0.3
	arena.emerald_max_interval_seconds = 0.4
	root.add_child(arena)

	# Wait for the emerald, then freeze the spawner so it doesn't refresh.
	var em: Node = null
	for i in 180:
		await process_frame
		var nodes: Array = get_nodes_in_group(&"pickups")
		if nodes.size() > 0:
			em = nodes[0]
			break
	arena.emerald_scene = null
	for i in 90:  # let the gem rise/spin + HUD springs settle
		await process_frame

	var img: Image = root.get_texture().get_image()
	img.save_png("res://tests/_screenshot_phase1.png")
	print("PROBE: saved _screenshot_phase1.png (", img.get_width(), "x", img.get_height(),
			") emerald_present=", em != null)
	quit(0)
