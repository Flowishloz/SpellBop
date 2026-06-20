## probe_rally_window.gd — verifies the LATE-RALLY SHIELD WINDOW (anti-spam, presentation read):
## CardCasterComponent.has_incoming_threat() pops the DEFENSE card in for an incoming ball at ANY distance
## until the ball has been rallied to the threshold, after which the reaction distance SHRINKS per reflect
## (down to a floor) — so sustaining a long rally needs timing, not mashing the auto-appearing shield.
## Defaults asserted: threshold 5, base 1400, shrink 230/reflect, floor 300 (sim units).
## Run: <godot> --headless --path . -s res://tests/probe_rally_window.gd
extends SceneTree

var _fails: int = 0
var _caster: Node
var _container: Node
var _dummy: Node
var _def_card: Resource  # a WALL defense card (for the whiff-gate tests)


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _find_card_caster(wiz: Node) -> Node:
	for c in wiz.get_children():
		if c.has_method(&"make_defense_available"):
			return c
	return null


func _init() -> void:
	_run()


## Spawn ONE hostile ball [param d] sim units down-court (moving toward the wizard at y=0) with [param r]
## reflects banked, assert has_incoming_threat() == [param expected], then free it.
func _expect(d: int, r: int, expected: bool, label: String) -> void:
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	_container.add_child(fb)
	await process_frame
	fb.set_global_fixed_position(SGFixed.vector2(0, SGFixed.from_int(d)))
	fb.sync_to_physics_engine()
	fb.set_hit_source(_dummy)            # hostile (not our own throw)
	for _i in maxi(0, r):
		fb.add_reflect()
	fb.launch(0, -SGFixed.from_int(20), SGFixed.ONE)  # vy < 0 = toward the wizard at y=0
	_ck(_caster.has_incoming_threat() == expected, label)
	fb.queue_free()
	await process_frame


## SIM WHIFF GATE: spawn ONE incoming ball [param d] units down-court with [param r] reflects, assert
## _defense_block_whiffs(def_card) == [param expected] (true = a too-early block that WHIFFS), then free it.
func _expect_whiff(d: int, r: int, expected: bool, label: String) -> void:
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	_container.add_child(fb)
	await process_frame
	fb.set_global_fixed_position(SGFixed.vector2(0, SGFixed.from_int(d)))
	fb.sync_to_physics_engine()
	fb.set_hit_source(_dummy)
	for _i in maxi(0, r):
		fb.add_reflect()
	fb.launch(0, -SGFixed.from_int(20), SGFixed.ONE)
	_ck(_caster._defense_block_whiffs(_def_card) == expected, label)
	fb.queue_free()
	await process_frame


func _run() -> void:
	await process_frame
	_container = Node.new()
	_container.name = "Projectiles"
	root.add_child(_container)

	var wiz: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz)
	await process_frame
	if "local_tick_driver_enabled" in wiz:
		wiz.local_tick_driver_enabled = false
	wiz.set_global_fixed_position(SGFixed.vector2(0, 0))
	wiz.sync_to_physics_engine()

	_caster = _find_card_caster(wiz)
	_ck(_caster != null, "wizard has a CardCasterComponent")
	if _caster == null:
		quit(1)
		return
	# Point the caster's threat scan at our container (the scene path won't resolve in the probe).
	_caster.projectile_container_path = NodePath("/root/Projectiles")

	_dummy = Node2D.new()
	root.add_child(_dummy)  # a non-wizard hit source so the ball reads as hostile

	# Below the threshold: ANY distance pops the shield in (unchanged generous warning).
	await _expect(1600, 0, true, "fresh ball (reflect 0) far away: shield pops in (any distance)")
	await _expect(1100, 5, true, "reflect 5, dy 1100 (< 1170 window): shield pops in")

	# At/past the threshold: a FAR ball no longer pops it in — the window has shrunk.
	await _expect(1600, 5, false, "reflect 5, dy 1600 (> 1170 window): shield stays tucked (no spam pop-in)")

	# The window keeps shrinking per reflect — the SAME distance flips from in to out one reflect later.
	await _expect(1100, 6, false, "reflect 6, dy 1100 (> 940 window): shield stays tucked (window shrank vs reflect 5)")

	# Deep rally: only a CLOSE ball pops it in, and never later than the floor.
	await _expect(900, 9, false, "reflect 9, dy 900 (> 300 floor): shield stays tucked")
	await _expect(200, 9, true, "reflect 9, dy 200 (< 300 floor): shield still pops in at the floor (hard, not impossible)")

	# ===== SIM WHIFF GATE — a too-early block in a deep rally whiffs (no barrier; the cooldown punishes). ==
	# Find a WALL defense card (buff defense never whiffs — it is proactive).
	for s in [1, 2, 3]:
		var c: Resource = _caster.call(&"_card_for_slot", s)
		if c != null and int(c.card_type) == 1 and float(c.buff_duration) <= 0.0:  # 1 = DEFENSE, wall (not buff)
			_def_card = c
			break
	_ck(_def_card != null, "caster has a WALL defense card to gate")
	if _def_card != null:
		# reflect 7: pop-in 710, capture window 710 x 0.6 = 426 (sim units).
		await _expect_whiff(900, 7, true, "deep rally, ball far (dy 900 > pop-in): block WHIFFS")
		await _expect_whiff(600, 7, true, "deep rally, ball popped-in but too early (dy 600 > 426 capture): block WHIFFS")
		await _expect_whiff(250, 7, false, "deep rally, ball inside the capture window (dy 250 < 426): block LANDS")
		# Below the threshold a mistimed press never whiffs — DEFENSE deploys anytime (unchanged).
		await _expect_whiff(900, 0, false, "fresh attack (reflect 0), ball far: never whiffs (deploy anytime)")
		await _expect_whiff(900, 4, false, "early rally (reflect 4 < threshold), ball far: never whiffs")

	if _fails == 0:
		print("RALLY WINDOW PROBE: ALL PASS")
		quit(0)
	else:
		print("RALLY WINDOW PROBE: %d FAILURE(S)" % _fails)
		quit(1)
