## screenshot_postgame.gd — captures the ROUND-BREAK and MATCH-END screens
## (expanded cards + stats/podium) for visual formatting audits.
## NOT headless. Saves tests/_screenshot_postround.png + _postmatch.png.
## Run: <godot> --path . -s res://tests/screenshot_postgame.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/match_arena.tscn")
	var arena: Node = packed.instantiate()
	var ai_brain: Node = arena.get_node("Opponent/AIBrain")
	ai_brain.cast_interval_ticks = 0
	ai_brain.card_interval_ticks = 0
	ai_brain.counter_enabled = false
	ai_brain.reaction_distance = 0.0
	ai_brain.track_deadzone = 100000.0
	arena.post_round_seconds = 30.0  # park in the break while we shoot
	root.add_child(arena)
	for i in 30:
		await process_frame

	# ROUND BREAK: KO the opponent once (best-of-3 -> POST_ROUND).
	arena.get_node("Opponent/Health").apply_damage(5)
	await _wait_real(1.6)  # springs settle
	_save("res://tests/_screenshot_postround.png")

	# MATCH END: KO again in round 2 (score 2-0 -> MATCH_OVER + podium).
	# Sub-phase 3: end the parked break NOW by forcing the resolver's live countdown to
	# expire (post_round_seconds is cached as ticks at setup, so poke the countdown, not it).
	if arena._roundflow != null:
		arena._roundflow._countdown = 1
	await _wait_real(0.8)  # round 2 starts
	arena.get_node("Opponent/Health").apply_damage(5)
	await _wait_real(1.8)
	_save("res://tests/_screenshot_postmatch.png")
	quit(0)


func _wait_real(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _save(path: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png(path)
	print("PROBE: saved ", path)
