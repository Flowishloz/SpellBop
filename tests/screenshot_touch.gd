## screenshot_touch.gd — visual proof of the Sprint 17 touch controls: holds the
## fireball CAST button (charge ring lit) and deflects the movement JOYSTICK so
## both render active beside the dash button. Saves tests/_screenshot_touch.png.
## NOT headless (needs a window/GPU). Run: <godot> --path . -s res://tests/screenshot_touch.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	root.add_child(arena)
	for i in 50:
		await process_frame

	# Light the fireball button: press + hold so the charge ring fills.
	var cast_btn: Node = arena.get_node("MatchHUD/CastButton")
	cast_btn._press()
	# Summon + deflect the movement joystick to the left.
	var joy: Node = arena.get_node("MoveJoystickHUD")
	joy._begin(Vector2(250, 1480), 0)
	joy._drag(Vector2(250 - 120, 1480))
	for i in 80:  # let the charge ring grow + press swell ease in
		await process_frame

	var img: Image = root.get_texture().get_image()
	img.save_png("res://tests/_screenshot_touch.png")
	print("PROBE: saved _screenshot_touch.png (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
