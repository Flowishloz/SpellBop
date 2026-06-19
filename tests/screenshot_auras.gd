## screenshot_auras.gd — renders match_arena with the new character particles forced on, so the DBZ
## CHARGE aura (CastParticles, feet-up), the green BOON aura, and the hover TRAIL (motes) are all visible.
## Disables each animator's _process so the forced `emitting` isn't reconciled away. NOT headless — needs
## a GPU. Run: <godot> --path . -s res://tests/screenshot_auras.gd
extends SceneTree

const OUT := "res://tests/_screenshot_auras.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var gs: Node = root.get_node_or_null("GameSettings")
	if gs != null:
		gs.set(&"hover_mode", true)
	root.add_child(load("res://scenes/match_arena.tscn").instantiate())
	for i in 90:
		await process_frame
	for wiz in get_nodes_in_group(&"wizards"):
		var anim: Node = wiz.get_node_or_null(^"WizardAnimator")
		if anim != null:
			anim.set_process(false)  # stop the aura updater so the forced emitting sticks
		for path in ["WizardRig/CastParticles", "WizardRig/HoverTrail", "WizardRig/BuffAura"]:
			var p: Node = wiz.get_node_or_null(path)
			if p != null:
				p.set(&"emitting", true)
	for i in 70:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: auras -> ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
