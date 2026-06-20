## screenshot_card_art.gd — visual proof of the Card Creation Engine assembly. Boots the Decks builder
## with the PLACEHOLDER base_art injected into the catalog cards IN MEMORY ONLY (the resource cache; never
## saved — the user's .tres files + profile.cfg are untouched), captures the pill tiles + the Big Inspect,
## then a standalone match_card_ui instance. NOT headless — needs a real window/GPU.
##   <godot> --path . -s res://tests/screenshot_card_art.gd
extends SceneTree

const ART := "res://resources/cards/art/_placeholder_base_art.png"
const OUT_BUILDER := "res://tests/_cardart_builder.png"
const OUT_INSPECT := "res://tests/_cardart_inspect.png"
const OUT_MATCH := "res://tests/_cardart_match.png"
const OUT_FILTER := "res://tests/_cardart_filter.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	# Inject the placeholder illustration into every catalog card — IN THE RESOURCE CACHE ONLY (load()
	# returns the same cached instance the tiles use; nothing is written to disk).
	var tex: Texture2D = load(ART) if ResourceLoader.exists(ART) else null
	print("placeholder art loaded: ", tex != null)
	var keep: Array = []   # STRONG refs so the mutated cards aren't freed + reloaded fresh before the scene builds
	for id in CardCatalog.all_ids():
		var c := CardCatalog.card_for(id)
		if c != null and tex != null:
			c.card_art = tex
			keep.append(c)
	print("spark_bolt card_art set: ", CardCatalog.card_for(&"spark_bolt").card_art != null)

	var pp: Node = root.get_node_or_null("PlayerProfile")
	if pp != null:
		pp.deck = {
			"attack": [&"spark_bolt", &"slow_boulder", &"swift_dart"],
			"defense": [&"gaeas_wall", &"hermes_boon"],
			"counter": [&"icey_retort"],
		}
		pp.deck_name = "Art Test"

	var packed: PackedScene = load("res://scenes/decks.tscn")
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	for i in 30:
		await process_frame
	inst._apply_state(true, false)
	inst._refresh()
	for i in 30:
		await process_frame
	root.get_texture().get_image().save_png(OUT_BUILDER)
	print("saved ", OUT_BUILDER)

	if inst.has_method("_open_filter_popup"):
		inst._open_filter_popup()
		for i in 18:
			await process_frame
		root.get_texture().get_image().save_png(OUT_FILTER)
		print("saved ", OUT_FILTER)
		inst._close_overlay()
		for i in 6:
			await process_frame

	inst._open_inspect(&"spark_bolt", &"inventory", -1)
	for i in 20:
		await process_frame
	root.get_texture().get_image().save_png(OUT_INSPECT)
	print("saved ", OUT_INSPECT)
	inst._close_overlay()
	inst.queue_free()
	for i in 6:
		await process_frame

	# Standalone in-round card (5:7) on a plain backdrop.
	var mc_packed: PackedScene = load("res://scenes/match_card_ui.tscn")
	if mc_packed != null:
		# LEFT: with card_art. RIGHT: no card_art → procedural type-glyph fallback.
		var mc: Control = mc_packed.instantiate()
		mc.position = Vector2(40, 610)
		root.add_child(mc)
		if mc.has_method("setup"):
			mc.setup(CardCatalog.card_for(&"spark_bolt"))
		var noart := CardCatalog.card_for(&"gaeas_wall").duplicate() as CardResource
		noart.card_art = null
		var mc2: Control = mc_packed.instantiate()
		mc2.position = Vector2(560, 610)
		root.add_child(mc2)
		if mc2.has_method("setup"):
			mc2.setup(noart)
		for i in 24:
			await process_frame
		root.get_texture().get_image().save_png(OUT_MATCH)
		print("saved ", OUT_MATCH)
	quit(0)
