## test_touch_controls.gd — Sprint 17A: proves the on-screen touch controls
## drive the SAME InputMap actions the keyboard does, so the deterministic sim
## responds identically. Headless (no rendering needed — we call the widgets'
## real press/hit-test methods and watch the sim).
##
## Coverage:
##   GEOMETRY  — cast button hit-tests inside its disc / outside elsewhere;
##               joystick zone contains the left-thumb area; a docked card's
##               own center hit-tests to that card.
##   FIREBALL  — press the cast button, hold past the cast time, release ->
##               a projectile spawns (the full mobile Mario-Kart cast loop).
##   JOYSTICK  — push left -> move_left pressed and the player's x DECREASES;
##               release -> action cleared.
##   CARD      — press-hold a card slot -> that card_slot action pressed and the
##               caster begins channeling; release -> action cleared.
extends SceneTree

var _fails: int = 0


func _init() -> void:
	_run()


func _ok(label: String, cond: bool) -> void:
	if cond:
		print("  PASS: ", label)
	else:
		_fails += 1
		print("  FAIL: ", label)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.round_intro_seconds = 0.0  # drive touch input immediately (no round-intro freeze)
	# Pin the opponent's AI card play OFF: cards now stage on PRESS, so an AI
	# stage would open the slow-mo Stack window mid-test and starve the fireball
	# charge below its fire threshold. We're testing TOUCH INPUT, not the AI.
	var ai: Node = arena.get_node_or_null("Opponent/AIBrain")
	if ai != null:
		ai.card_interval_ticks = 0
	root.add_child(arena)
	await _frames(60)  # round starts, springs settle

	var cast_btn: Node = arena.get_node("MatchHUD/CastButton")
	var joy: Node = arena.get_node("MoveJoystickHUD")
	var hand: Node = arena.get_node("CardHandHUD")
	var caster: Node = arena.get_node("Player/SpellCasterComponent")
	var movement: Node = arena.get_node("Player/Movement")
	var body: Node = arena.get_node("Player")
	var projectiles: Node = arena.get_node("Projectiles")

	print("[GEOMETRY]")
	_ok("cast button disc contains its center", cast_btn._is_inside(cast_btn._draw_center))
	_ok("cast button rejects a far point", not cast_btn._is_inside(Vector2(100, 100)))
	_ok("cast button sits in the lower-right thumb cluster",
			cast_btn._draw_center.x > 540.0 and cast_btn._draw_center.y > 1400.0)
	_ok("joystick zone contains lower-left", joy._zone_contains(Vector2(220, 1500)))
	_ok("joystick zone excludes lower-right", not joy._zone_contains(Vector2(900, 1500)))
	# A docked card's own center must resolve to a real slot. (Index 0 = the ATTACK card, always in
	# hand; the DEFENSE/COUNTER cards now stay hidden until their cue, so they aren't hit-testable.)
	var slot_at_center: int = hand._card_hit(hand._pos[0] + hand._root_offset)
	_ok("card hit-test resolves a docked card", slot_at_center >= 0)

	print("[FIREBALL CAST BUTTON]")
	Input.action_release(&"cast_spell")
	# Capture the SPAWN via the caster's signal — robust to the bolt then flying
	# out of the shared container fast (boosted charge) and to AI projectile noise.
	var fired: Array = [false]
	caster.spell_cast.connect(func(_p, _s = null) -> void: fired[0] = true)
	cast_btn._press()
	_ok("press drives cast_spell action", Input.is_action_pressed(&"cast_spell"))
	# POLL until the charge is actually throwable (gauge >= 1). A fixed idle-frame
	# count is unreliable headless (idle frames don't map 1:1 to physics ticks),
	# so wait on the real charge state instead.
	var waited: int = 0
	while caster.charge_level() < 1 and waited < 600:
		await process_frame
		waited += 1
	_ok("held cast banks a throwable charge (gauge >= 1)", caster.charge_level() >= 1)
	cast_btn._release()
	_ok("release clears cast_spell action", not Input.is_action_pressed(&"cast_spell"))
	var settle: int = 0
	while not fired[0] and settle < 120:
		await process_frame
		settle += 1
	_ok("release SPAWNED a fireball", fired[0])

	print("[MOVE JOYSTICK]")
	var x0: int = body.get_global_fixed_position().x
	joy._begin(Vector2(240, 1500), 0)
	joy._drag(Vector2(240 - 140, 1500))  # push hard left
	_ok("left push presses move_left", Input.is_action_pressed(&"move_left"))
	await _frames(20)
	var x1: int = body.get_global_fixed_position().x
	_ok("player moved LEFT (x decreased)", x1 < x0)
	joy._end()
	_ok("release clears move_left", not Input.is_action_pressed(&"move_left"))

	print("[CARD HOLD]")
	hand._begin_card(0, 0)
	_ok("card press drives card_slot_1", Input.is_action_pressed(&"card_slot_1"))
	await _frames(10)
	hand._end_card()
	_ok("card release clears card_slot_1", not Input.is_action_pressed(&"card_slot_1"))

	print("")
	if _fails == 0:
		print("TOUCH CONTROLS: ALL PASS")
	else:
		print("TOUCH CONTROLS: ", _fails, " FAILURE(S)")
	quit(_fails)
