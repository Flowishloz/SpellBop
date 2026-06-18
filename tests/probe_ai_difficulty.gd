## probe_ai_difficulty.gd — verifies the 3-tier AI difficulty preset + the OFFLINE menu build.
##
## PART 1: for each GameSettings.ai_difficulty tier, instantiates the real opponent
## (res://scenes/opponent.tscn — the AIBrainComponent) and asserts the brain's tunables
## match that tier's preset. CRUCIALLY, NORMAL (1) must equal the shipped @export
## defaults — that is the tier the headless determinism sweep runs at, so a drift here
## would silently perturb the whole sweep.
##
## PART 2: instantiates the menu (res://scenes/ui/menu_flow.tscn) and confirms it builds
## its panels (incl. the new difficulty tray) without error and exposes the selector hooks.
##
## Run: <godot> --headless --path . -s res://tests/probe_ai_difficulty.gd
extends SceneTree

var _fails: int = 0


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _init() -> void:
	_run()


func _find_brain(opp: Node) -> Node:
	for c in opp.get_children():
		if c is AIBrainComponent:
			return c
	return null


func _run() -> void:
	await process_frame
	var gs: Node = root.get_node_or_null(^"/root/GameSettings")
	_ck(gs != null, "GameSettings autoload present")
	if gs == null:
		quit(1)
		return
	_ck("ai_difficulty" in gs, "GameSettings exposes ai_difficulty")
	_ck(gs.has_method(&"set_ai_difficulty"), "GameSettings exposes set_ai_difficulty()")

	# tier -> expected [block_gate_modulo, reaction_delay_ticks, counter_every_n_windows, block_range]
	var expected := {
		0: [4, 45, 3, 260.0],   # EASY  — blocks rarely, slow reactions
		1: [3, 30, 2, 350.0],   # NORMAL — the shipped @export defaults (the sweep's tier)
		2: [1, 10, 1, 460.0],   # HARD  — always blocks, fast reactions
	}
	var scene: PackedScene = load("res://scenes/opponent.tscn")
	_ck(scene != null, "opponent.tscn loaded")
	for tier in [0, 1, 2]:
		gs.ai_difficulty = tier            # set BEFORE _ready so the brain reads THIS tier
		var opp: Node = scene.instantiate()
		if "local_tick_driver_enabled" in opp:
			opp.local_tick_driver_enabled = false
		root.add_child(opp)                # triggers AIBrain._ready -> _apply_difficulty_preset()
		await process_frame
		var brain: Node = _find_brain(opp)
		_ck(brain != null, "tier %d: opponent has an AIBrainComponent" % tier)
		if brain != null:
			var exp: Array = expected[tier]
			_ck(brain.block_gate_modulo == exp[0],
					"tier %d: block_gate_modulo == %d (got %d)" % [tier, exp[0], brain.block_gate_modulo])
			_ck(brain.reaction_delay_ticks == exp[1],
					"tier %d: reaction_delay_ticks == %d (got %d)" % [tier, exp[1], brain.reaction_delay_ticks])
			_ck(brain.counter_every_n_windows == exp[2],
					"tier %d: counter_every_n_windows == %d (got %d)" % [tier, exp[2], brain.counter_every_n_windows])
			_ck(is_equal_approx(brain.block_range, exp[3]),
					"tier %d: block_range == %.0f (got %.0f)" % [tier, exp[3], brain.block_range])
		opp.queue_free()
		await process_frame
	gs.ai_difficulty = 1  # leave the autoload at the Normal default

	# --- PART 2: the OFFLINE menu builds with the difficulty selector ---
	var menu_scene: PackedScene = load("res://scenes/ui/menu_flow.tscn")
	_ck(menu_scene != null, "menu_flow.tscn loaded")
	if menu_scene != null:
		var menu: Node = menu_scene.instantiate()
		root.add_child(menu)
		await process_frame
		_ck(menu.get_child_count() > 0, "menu built its panels without error")
		for hook in ["_open_difficulty", "_on_play_offline", "_build_difficulty_tray"]:
			_ck(menu.has_method(hook), "menu exposes %s()" % hook)
		menu.queue_free()
		await process_frame

	if _fails == 0:
		print("AI DIFFICULTY PROBE: ALL PASS")
		quit(0)
	else:
		print("AI DIFFICULTY PROBE: %d FAILURE(S)" % _fails)
		quit(1)
