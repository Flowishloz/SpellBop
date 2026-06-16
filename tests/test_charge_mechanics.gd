## test_charge_mechanics.gd — Gameplay phase: (1) cards COMMIT ON PRESS (no
## charge/channel time — an ATTACK stages on the very first press tick), and
## (2) the fireball's size scales with the charge GAUGE: 1 = base, 2 = +10%,
## 3 = +25%. Drives the real match_arena with the player tick-driver OFF so the
## caster components can be stepped deterministically.
##
## Run: godot --headless --path . -s res://tests/test_charge_mechanics.gd
extends SceneTree

const ONE: int = 65536

var _fails: int = 0
var _captured: Node = null
var _player: Node = null
var _spell: Node = null
var _cards: Node = null
var _movement: Node = null
var _player_y: int = 0


func _initialize() -> void:
	await _run()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _on_cast(projectile: Node, _spell = null) -> void:
	_captured = projectile


func _circle_radius_fp(obj: Node) -> int:
	for child in obj.get_children():
		if child is SGCollisionShape2D and child.shape != null and child.shape is SGCircleShape2D:
			return child.shape.radius
	return 0


func _place(x_fp: int) -> void:
	_player.set_global_fixed_position(SGFixed.vector2(x_fp, _player_y))
	_player.sync_to_physics_engine()


## Clear the cooldown, hold cast until the charge reaches EXACTLY [target] gauge,
## then release. Robust to the scene's tuning (cooldown 1.8s = 108 ticks, the
## charge curve) — we read the live gauge instead of guessing tick counts.
func _fire_at_level(target: int) -> Node:
	for i in 150:
		_spell._network_process({})        # fully clear the 108-tick cooldown
	_captured = null
	var guard: int = 0
	while _spell.charge_level() < target and guard < 400:
		_spell._network_process({"c": 1})  # hold the cast button
		guard += 1
	var lvl: int = _spell.charge_level()
	_spell._network_process({})            # release -> RELEASE-FIRE
	return _captured if (is_instance_valid(_captured) and lvl == target) else null


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	root.add_child(arena)
	for i in 20:
		await process_frame

	_player = arena.get_node("Player")
	_spell = _player.get_node("SpellCasterComponent")
	_cards = _player.get_node("CardCasterComponent")
	_movement = _player.get_node("Movement")
	# Take full manual control of the sim so direct _network_process steps aren't
	# interleaved with the player's own tick driver.
	_player.local_tick_driver_enabled = false
	_spell.spell_cast.connect(_on_cast)
	_player_y = _player.get_global_fixed_position().y
	_place(0)

	# ============================================================
	# FIREBALL SIZE BY CHARGE GAUGE: 1 = base, 2 = +10%, 3 = +25%.
	# cast_ticks=30 (0.5s), max_charge_ticks=90 (1.5s), boost_range=60:
	#  level 1 @ charge 30-59, level 2 @ 60-89, level 3 @ 90.
	# ============================================================
	print("[CHARGE SIZE]")
	var b1: Node = _fire_at_level(1)
	_check(b1 != null, "gauge 1 fired a fireball")
	var r1: int = _circle_radius_fp(b1) if b1 != null else 0
	var b2: Node = _fire_at_level(2)
	_check(b2 != null, "gauge 2 fired a fireball")
	var r2: int = _circle_radius_fp(b2) if b2 != null else 0
	var b3: Node = _fire_at_level(3)
	_check(b3 != null, "gauge 3 fired a fireball")
	var r3: int = _circle_radius_fp(b3) if b3 != null else 0

	_check(r1 == SGFixed.from_float(24.0), "gauge 1 radius == base 24u (%d), got %d" % [SGFixed.from_float(24.0), r1])
	_check(r2 == SGFixed.from_float(24.0 * 1.15), "gauge 2 radius == 27.6u (+15%%) (%d), got %d" % [SGFixed.from_float(27.6), r2])
	_check(r3 == SGFixed.from_float(24.0 * 1.35), "gauge 3 radius == 32.4u (+35%%) (%d), got %d" % [SGFixed.from_float(32.4), r3])
	# Ratios, independent of the exact base.
	_check(absi(r2 * 100 / maxi(1, r1) - 115) <= 1, "gauge 2 is ~1.15x gauge 1")
	_check(absi(r3 * 100 / maxi(1, r1) - 135) <= 1, "gauge 3 is ~1.35x gauge 1")

	# The bigger bolt must STILL clamp inside the lane at the edge (the spawn
	# clamp uses the CHARGED radius, not the base).
	print("[CHARGED BOLT STILL IN BOUNDS]")
	var bound: int = _movement.arena_half_width_fp()
	_place(bound)
	var be: Node = _fire_at_level(3)  # gauge 3, radius 30
	if be != null:
		var pos: SGFixedVector2 = be.get_global_fixed_position()
		var re: int = _circle_radius_fp(be)
		_check(absi(pos.x) + re <= bound,
			"gauge-3 bolt at +edge stays in bounds (|%d|+%d <= %d)" % [pos.x, re, bound])
	_place(0)

	# ============================================================
	# TAP-CAST (Sprint 22): a quick TAP (cast released BEFORE the 30-tick charge
	# minimum) immediately fires a LOW-TIER, uncharged, base-size fireball.
	# ============================================================
	print("[TAP-CAST]")
	for i in 150:
		_spell._network_process({})         # clear the cooldown
	_captured = null
	_spell._network_process({"c": 1})       # press (charge tick 1)
	_spell._network_process({"c": 1})       # ... still well below the 30-tick minimum
	_spell._network_process({"c": 1})
	_check(_spell.charge_level() == 0, "quick tap stays gauge 0 (below the charge minimum)")
	_spell._network_process({})             # RELEASE before the minimum -> TAP-CAST fires
	_check(is_instance_valid(_captured) and _captured != null, "quick tap FIRED a fireball (was a drain before)")
	var rt: int = _circle_radius_fp(_captured) if _captured != null else 0
	_check(rt == SGFixed.from_float(24.0), "tap-cast fireball is base size 24u (uncharged), got %d" % rt)

	# ============================================================
	# CARDS COMMIT ON PRESS: an ATTACK stages on the FIRST press tick.
	# ============================================================
	print("[CARD STAGES ON PRESS]")
	_check(not _cards.is_staging(), "no card staged before press")
	_cards._network_process({"k": 1})   # press slot 1 (attack) — single tick
	_check(_cards.is_staging(), "ATTACK staged on the FIRST press tick (no channel)")

	print("")
	if _fails == 0:
		print("CHARGE MECHANICS TEST: ALL PASS")
		quit(0)
	else:
		print("CHARGE MECHANICS TEST: %d FAILURE(S)" % _fails)
		quit(1)
