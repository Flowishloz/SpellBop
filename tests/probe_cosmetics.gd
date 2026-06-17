## probe_cosmetics.gd — HEADLESS smoke for the Cosmetics scene + the podium rig.
## Verifies: (1) SkinCatalog enumerates the 5 skins export-safe (load-by-path); (2) the podium trim
## resolves facing=FRONT (the new facing_override) with the NEON skin uploaded (color_count=8);
## (3) the whole Cosmetics scene builds its diorama + UI overlay in _ready without error.
## Run: <godot> --headless --path . -s res://tests/probe_cosmetics.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	# 1) Catalog enumerates (the export-safe registry).
	var skins: Array = SkinCatalog.skins()
	print("CATALOG size=", skins.size())
	for s in skins:
		print("  id=", s.id, " name='", s.display_name, "' folder='", s.texture_folder_override, "'")

	# 2) The podium rig trim: forced FRONT facing + the NEON skin uploaded to the shader.
	var trim: Node = load("res://scenes/cosmetics_wizard.tscn").instantiate()
	root.add_child(trim)
	for i in 6:
		await process_frame
	var anim: Node = trim.get_node_or_null("WizardAnimator")
	var spr: Node = trim.get_node_or_null("WizardRig/Sprite3D")
	var tex: Texture2D = spr.get(&"texture") as Texture2D if spr != null else null
	var mat: ShaderMaterial = spr.get(&"material_override") as ShaderMaterial if spr != null else null
	var cc: int = int(mat.get_shader_parameter(&"color_count")) if mat != null else -1
	print("TRIM facing=", str(anim.get(&"_facing")) if anim != null else "?",
		" tex=", tex.resource_path.get_file() if tex != null else "<none>",
		" color_count=", cc)

	# 3) Full Cosmetics scene smoke (builds the 3D diorama + the CanvasLayer UI in _ready).
	var cos: Node = load("res://scenes/cosmetics.tscn").instantiate()
	root.add_child(cos)
	for i in 6:
		await process_frame
	print("COSMETICS built OK; root children=", cos.get_child_count())
	quit(0)
