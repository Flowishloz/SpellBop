## probe_facing_check.gd — HEADLESS, deterministic check of the directional + premium-skin logic
## (no rendering, so no camera/bridge fragility): instances the wizards and prints each one's
## resolved facing + the actual pose texture path the animator selected.
## Expected:  player -> back / idle_back   |  opponent -> front / idle_front
##            opponent+set_skin(cyber) -> front / cyber_wizard/idle_front  (premium folder override)
## Run: <godot> --headless --path . -s res://tests/probe_facing_check.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var blue: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(blue)
	var red: Node = load("res://scenes/opponent.tscn").instantiate()
	root.add_child(red)
	var cyber: Node = load("res://scenes/opponent.tscn").instantiate()
	root.add_child(cyber)
	for i in 4:
		await process_frame
	var anim: Node = cyber.get_node_or_null("WizardAnimator")
	if anim != null:
		anim.set_skin(load("res://assets_final/skins/cyber_wizard.tres"))
	for i in 6:
		await process_frame

	_report("player(blue)", blue)
	_report("opponent(red)", red)
	_report("opponent+cyber", cyber)
	quit(0)


func _report(label: String, wiz: Node) -> void:
	var anim: Node = wiz.get_node_or_null("WizardAnimator")
	var spr: Node = wiz.get_node_or_null("WizardRig/Sprite3D")
	var facing: String = str(anim.get(&"_facing")) if anim != null else "?"
	var folder: String = str(anim.get(&"_skin_folder")) if anim != null else "?"
	var tex: Texture2D = spr.get(&"texture") as Texture2D if spr != null else null
	var path: String = tex.resource_path.get_file() if tex != null else "<none>"
	var full: String = tex.resource_path if tex != null else "<none>"
	print("  %-16s facing=%-5s tex=%-22s folder=%s" % [label, facing, path, folder])
	if full.contains("cyber"):
		print("      (premium folder texture: ", full, ")")
