## screenshot_decks.gd — visual ground truth for the Decks overhaul. Boots scenes/decks.tscn, captures the
## "My Decks" landing state, then enters the builder state (with a representative half-filled deck) and
## captures that too. NOT headless — needs a real window/GPU.
##   <godot> --path . -s res://tests/screenshot_decks.gd
## SAFE: sets the deck IN MEMORY only (never _save) — the user's saved profile.cfg is untouched.
extends SceneTree

const OUT_LANDING := "res://tests/_decks_landing.png"
const OUT_BUILDER := "res://tests/_decks_builder.png"
const OUT_INSPECT := "res://tests/_decks_inspect.png"
const OUT_QUANTITY := "res://tests/_decks_quantity.png"
const OUT_DECKINSPECT := "res://tests/_decks_inspect_deck.png"
const OUT_DRAGFOCUS := "res://tests/_decks_dragfocus.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var pp: Node = root.get_node_or_null("PlayerProfile")
	if pp != null:
		# A representative half-built deck so the builder shows filled + empty slots (in-memory; NOT saved).
		pp.deck = {
			"attack": [&"spark_bolt", &"slow_boulder", &"swift_dart"],
			"defense": [&"gaeas_wall", &"hermes_boon"],
			"counter": [&"icey_retort"],
		}
		pp.deck_name = "Aggro Test"   # in-memory only (NOT set_deck_name, which would persist)
	var packed: PackedScene = load("res://scenes/decks.tscn")
	if packed == null:
		print("DECKS SHOT FAIL: scene did not load")
		quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	for i in 30:
		await process_frame
	root.get_texture().get_image().save_png(OUT_LANDING)
	print("saved ", OUT_LANDING)

	# Enter the builder state (no animation) + rebuild, then capture.
	inst._apply_state(true, false)
	inst._refresh()
	for i in 30:
		await process_frame
	root.get_texture().get_image().save_png(OUT_BUILDER)
	print("saved ", OUT_BUILDER)

	# Big inspect modal (50/50, over a darkened backdrop).
	inst._open_inspect(&"spark_bolt", &"inventory", -1)
	for i in 20:
		await process_frame
	root.get_texture().get_image().save_png(OUT_INSPECT)
	print("saved ", OUT_INSPECT)

	# Quantity prompt (dynamic cap).
	inst._close_overlay()
	inst._open_quantity(&"spark_bolt")
	for i in 20:
		await process_frame
	root.get_texture().get_image().save_png(OUT_QUANTITY)
	print("saved ", OUT_QUANTITY)

	# Deck-context inspect (match-card look + REMOVE / LOAD buttons).
	inst._close_overlay()
	inst._open_inspect(&"hermes_boon", &"deck", 1)
	for i in 20:
		await process_frame
	root.get_texture().get_image().save_png(OUT_DECKINSPECT)
	print("saved ", OUT_DECKINSPECT)

	# Drag-focus: simulate dragging an ATTACK card → non-attack cards dim/desaturate.
	inst._close_overlay()
	inst._drag_type = 0
	inst._apply_drag_focus(true)
	for i in 24:
		await process_frame
	root.get_texture().get_image().save_png(OUT_DRAGFOCUS)
	print("saved ", OUT_DRAGFOCUS)
	quit(0)
