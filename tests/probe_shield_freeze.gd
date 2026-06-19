## probe_shield_freeze.gd — verifies the SHIELD-CAPTURE MOTION LOCK (Task 3):
##   (1) while a barrier the wizard deployed HOLDS a captured ball, the owner's MovementComponent
##       reports is_frozen() and directional input does NOT move it (an instant, full lock);
##   (2) on release the lock lapses (after the short re-push TTL) and movement resumes;
##   (3) the freeze ("fz") round-trips through _save_state/_load_state (rollback-safe).
## Run: <godot> --headless --path . -s res://tests/probe_shield_freeze.gd
extends SceneTree

var _fails: int = 0


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _find_movement(wiz: Node) -> Node:
	for c in wiz.get_children():
		if c is MovementComponent:
			return c
	return null


## Duck-typed (is_charging is unique to the SpellCasterComponent) — avoids a type ref so the probe
## doesn't force an early compile of caster scripts before the autoloads register.
func _find_caster(wiz: Node) -> Node:
	for c in wiz.get_children():
		if c.has_method(&"is_charging"):
			return c
	return null


func _init() -> void:
	_run()


func _place(body: Node, x: int, y: int) -> void:
	body.set_global_fixed_position(SGFixed.vector2(SGFixed.from_int(x), SGFixed.from_int(y)))
	body.sync_to_physics_engine()


func _run() -> void:
	await process_frame
	var container := Node.new()
	container.name = "Projectiles"
	root.add_child(container)
	var wiz: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz)
	await process_frame
	if "local_tick_driver_enabled" in wiz:
		wiz.local_tick_driver_enabled = false  # we drive the components by hand
	_place(wiz, 0, 0)
	var mv: Node = _find_movement(wiz)
	_ck(mv != null, "wizard has a MovementComponent")
	if mv == null:
		quit(1)
		return
	_ck(not mv.is_frozen(), "fresh wizard: not frozen")

	# --- CONTROL: with no lock, movement input MOVES the wizard ---
	var x_before: int = wiz.get_global_fixed_position().x
	mv._network_process({InputCommand.KEY_X: 1})
	_ck(wiz.get_global_fixed_position().x > x_before, "CONTROL: input moves the wizard when free")
	_place(wiz, 0, 0)
	mv.halt()

	# --- Deploy a barrier owned by the wizard + a ball sitting in its capture band ---
	var bar: Node = load("res://scenes/barrier.tscn").instantiate()
	bar.local_tick_driver_enabled = false
	container.add_child(bar)
	await process_frame
	_place(bar, 0, 120)
	bar.deploy(SGFixed.from_int(100), SGFixed.from_int(20), 0, 0)
	bar.arm_window_of_affect(wiz, 1, SGFixed.ONE, 20, SGFixed.ONE, 0, 0)
	var released := [false]
	bar.capture_released.connect(func() -> void: released[0] = true)

	var dummy := Node2D.new()
	root.add_child(dummy)  # a non-wizard hit source so the ball is "hostile"
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	container.add_child(fb)
	await process_frame
	_place(fb, 0, 60)
	fb.set_hit_source(dummy)
	fb.launch(0, -SGFixed.from_int(20), SGFixed.ONE)

	# CAPTURE tick: the barrier grabs the ball and pushes the freeze onto its owner.
	bar._network_process({})
	_ck(fb.get_velocity_y() == 0, "ball captured (frozen on the wall, vy == 0)")
	_ck(mv.is_frozen(), "owner FROZEN once the hold begins")

	# FULL LOCK (committed to the block): a cast input must NOT start a fireball charge while frozen.
	var caster: Node = _find_caster(wiz)
	_ck(caster != null, "wizard has a SpellCasterComponent")
	if caster != null:
		caster._network_process({InputCommand.KEY_CAST: 1})
		_ck(not caster.is_charging(), "FROZEN: cast input does NOT start a charge (locked into the block)")

	# --- During the hold: input must NEVER move the wizard ---
	var pinned_x: int = wiz.get_global_fixed_position().x
	var moved_during_hold := false
	var held_ticks := 0
	for _i in 120:
		if released[0]:
			break
		bar._network_process({})        # re-pushes the freeze each held tick
		if released[0]:
			break
		mv._network_process({InputCommand.KEY_X: 1})  # frozen -> consumed, no movement
		if wiz.get_global_fixed_position().x != pinned_x:
			moved_during_hold = true
		held_ticks += 1
	_ck(not moved_during_hold, "FROZEN: input never moved the wizard across the whole hold (%d ticks)" % held_ticks)
	_ck(released[0], "the hold released (%d held ticks)" % held_ticks)
	_ck(mv.is_frozen(), "still frozen on the release tick (lock lapses just after)")

	# --- After release: the barrier stops pushing; the lock lapses within the TTL, movement resumes ---
	for _i in 4:
		mv._network_process({})
	_ck(not mv.is_frozen(), "UNFROZEN shortly after release")
	var rx0: int = wiz.get_global_fixed_position().x
	mv._network_process({InputCommand.KEY_X: 1})
	_ck(wiz.get_global_fixed_position().x > rx0, "movement RESUMES after release")
	if caster != null:
		caster._network_process({InputCommand.KEY_CAST: 1})
		_ck(caster.is_charging(), "casting RESUMES after release")

	# --- save/load round-trips the freeze ("fz") ---
	mv.apply_movement_freeze(5)
	_ck(mv.is_frozen(), "apply_movement_freeze arms the lock")
	var st: Dictionary = mv._save_state()
	_ck(st.has("fz") and int(st["fz"]) > 0, "save_state carries the freeze (fz=%s)" % str(st.get("fz")))
	var wiz2: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz2)
	await process_frame
	var mv2: Node = _find_movement(wiz2)
	if mv2 != null:
		mv2._load_state(st)
	_ck(mv2 != null and mv2.is_frozen(), "load_state restores the freeze on a fresh wizard")

	if _fails == 0:
		print("SHIELD FREEZE PROBE: ALL PASS")
		quit(0)
	else:
		print("SHIELD FREEZE PROBE: %d FAILURE(S)" % _fails)
		quit(1)
