## probe_shield_rally.gd — unit-verifies the SHIELD-REFLECT RALLY escalation:
##   (1) reflect_count + the rally speed multiplier (FireballController -> mover),
##   (2) the escalating speed cap (an over-cap launch clamps to base_cap, then base_cap x1.2),
##   (3) save/load determinism of reflect_count (rollback-safe),
##   (4) CardCasterComponent.make_defense_available() clears the DEFENSE slot cooldown.
## Run: <godot> --headless --path . -s res://tests/probe_shield_rally.gd
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


func _run() -> void:
	await process_frame

	# --- 1. reflect_count + rally speed multiplier ---
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	root.add_child(fb)
	await process_frame
	_ck(fb.get_reflect_count() == 0, "fresh ball: reflect_count == 0")
	_ck(fb.rally_speed_mult_fp() == SGFixed.ONE, "fresh ball: rally mult == 1.0")
	fb.add_reflect()
	_ck(fb.get_reflect_count() == 1, "after 1 reflect: count == 1")
	var g_fp: int = SGFixed.from_float(1.2)
	_ck(fb.rally_speed_mult_fp() == g_fp, "after 1 reflect: rally mult == 1.2x (%d vs %d)" % [fb.rally_speed_mult_fp(), g_fp])
	fb.add_reflect()
	_ck(fb.rally_speed_mult_fp() == SGFixed.mul(g_fp, g_fp), "after 2 reflects: rally mult == 1.44x")
	fb.queue_free()
	await process_frame

	# --- 2. escalating speed cap ---
	var fb2: Node = load("res://scenes/fireball.tscn").instantiate()
	fb2.local_tick_driver_enabled = false
	root.add_child(fb2)
	await process_frame
	var over: int = SGFixed.from_float(500.0)  # way over any base cap -> always clamps
	fb2.launch(0, over, SGFixed.ONE)
	fb2._network_process({})
	var cap0: int = absi(fb2.get_velocity_y())
	fb2.add_reflect()
	fb2.launch(0, over, SGFixed.ONE)
	fb2._network_process({})
	var cap1: int = absi(fb2.get_velocity_y())
	_ck(cap0 > 0 and cap1 > cap0, "escalating cap: reflected cap (%d) > base cap (%d)" % [cap1, cap0])
	var want1: int = SGFixed.mul(cap0, g_fp)
	_ck(absi(cap1 - want1) < SGFixed.from_float(0.5), "escalating cap: reflected cap ~= 1.2x base (got %d, want ~%d)" % [cap1, want1])

	# --- 3. save/load preserves reflect_count ---
	var st: Dictionary = fb2._save_state()
	_ck(st.has("movement") and (st["movement"] as Dictionary).has("rc") and int(st["movement"]["rc"]) == 1, "save_state carries reflect_count (rc=1)")
	var fb3: Node = load("res://scenes/fireball.tscn").instantiate()
	fb3.local_tick_driver_enabled = false
	root.add_child(fb3)
	await process_frame
	fb3._load_state(st)
	_ck(fb3.get_reflect_count() == 1, "load_state restores reflect_count == 1")

	# --- 4. make_defense_available() clears the DEFENSE slot cooldown ---
	var ply: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(ply)
	await process_frame
	var caster: Node = ply.get_node_or_null(^"CardCasterComponent")
	if caster == null:
		for c in ply.get_children():
			if c is CardCasterComponent:
				caster = c
				break
	_ck(caster != null, "player has a CardCasterComponent")
	if caster != null:
		var def_slot: int = 0
		for s in range(1, 4):
			var card: Variant = caster.get("card_slot_" + str(s))
			if card != null and card.card_type == CardResource.CardType.DEFENSE:
				def_slot = s
				break
		_ck(def_slot != 0, "caster has a DEFENSE slot (slot %d)" % def_slot)
		if def_slot != 0:
			caster._slot_cd[def_slot - 1] = 100  # force a cooldown
			_ck(caster.cooldown_ticks_remaining(def_slot) == 100, "DEFENSE slot is on cooldown before re-enable")
			caster.make_defense_available()
			_ck(caster.cooldown_ticks_remaining(def_slot) == 0, "make_defense_available cleared the DEFENSE cooldown")

	if _fails == 0:
		print("SHIELD RALLY PROBE: ALL PASS")
		quit(0)
	else:
		print("SHIELD RALLY PROBE: %d FAILURE(S)" % _fails)
		quit(1)
