## probe_two_wizards.gd — proves the SKIN system: player.tscn (blue skin) + opponent.tscn
## (red skin) are two RECOLOURS of the SAME base art, with INDEPENDENT per-instance materials
## (the animator's material duplicate). Renders them side by side and saves a PNG.
## Run (NEEDS A WINDOW/GPU): <godot> --path . -s res://tests/probe_two_wizards.gd
extends SceneTree

const OUT := "res://tests/_two_wizards.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.0, 5.0)
	cam.rotation = Vector3(deg_to_rad(-6.0), 0.0, 0.0)
	root.add_child(cam)
	cam.make_current()

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(20.0), 0.0)
	root.add_child(light)

	var blue: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(blue)
	var red: Node = load("res://scenes/opponent.tscn").instantiate()
	root.add_child(red)

	# Let _ready run (skin upload + idle pose), then separate the rigs (no sim ticks here, so
	# the VisualBridge never snaps them off this manual position).
	await process_frame
	await process_frame
	var br: Node3D = blue.get_node_or_null("WizardRig")
	var rr: Node3D = red.get_node_or_null("WizardRig")
	if br != null:
		br.position = Vector3(-1.6, 0.0, 0.0)
	if rr != null:
		rr.position = Vector3(1.6, 0.0, 0.0)

	for i in 30:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: saved ", OUT, " (", img.get_width(), "x", img.get_height(), ") — blue (L) vs red (R)")
	quit(0)
