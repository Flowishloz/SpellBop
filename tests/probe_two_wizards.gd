## probe_two_wizards.gd — proves the directional + skin systems in one shot:
##   L: player.tscn  (blue skin, cast_dir -1) -> shows BACK (no face)
##   C: opponent.tscn(red skin,  cast_dir +1) -> shows FRONT (face)
##   R: opponent.tscn + set_skin(cyber) -> FRONT, PREMIUM wide hat from the override folder + teal
## Renders them side by side and saves a PNG.
## Run (NEEDS A WINDOW/GPU): <godot> --path . -s res://tests/probe_two_wizards.gd
extends SceneTree

const OUT := "res://tests/_two_wizards.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.0, 6.6)
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
	var cyber: Node = load("res://scenes/opponent.tscn").instantiate()
	root.add_child(cyber)

	await process_frame
	await process_frame

	# Swap the right wizard to the PREMIUM cyber skin at runtime (proves set_skin + folder override).
	var anim: Node = cyber.get_node_or_null("WizardAnimator")
	if anim != null:
		anim.set_skin(load("res://assets_final/skins/cyber_wizard.tres"))

	var xs := {blue: -2.5, red: 0.0, cyber: 2.5}
	# Re-pin every frame so the VisualBridge easing can't drift them back to centre (and so the
	# zero per-frame delta keeps them in the idle pose, not "running").
	for i in 30:
		for w in xs:
			var rig: Node3D = w.get_node_or_null("WizardRig")
			if rig != null:
				rig.position = Vector3(xs[w], 0.0, 0.0)
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: saved ", OUT)
	for pair in [["L blue", blue], ["C red", red], ["R cyber", cyber]]:
		var a: Node = pair[1].get_node_or_null("WizardAnimator")
		var s: Node = pair[1].get_node_or_null("WizardRig/Sprite3D")
		var tx: Texture2D = s.get(&"texture") as Texture2D if s != null else null
		print("  ", pair[0], " facing=", a.get(&"_facing"), " tex=", tx.resource_path.get_file() if tx != null else "<none>")
	quit(0)
