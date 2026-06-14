## test_fire_shake.gd — Phase 5: firing a projectile adds 20% more camera trauma
## (fire_shake_multiplier = 1.2). Headless — reads the camera's trauma the moment
## a base fireball is fired.
##
## Run: <godot> --headless --path . -s res://tests/test_fire_shake.gd
extends SceneTree

var _fails: int = 0


func _init() -> void:
	_run()


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_scene = null
	# AI fires base fireballs quickly; no cards.
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 60
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	await process_frame

	_ck(is_equal_approx(arena.fire_shake_multiplier, 1.2),
		"fire_shake_multiplier = 1.2 (got %.2f)" % arena.fire_shake_multiplier)

	var cam: Node = arena.get_node("Camera3D")
	var caster: Node = arena.get_node("Opponent/SpellCasterComponent")
	# MatchController's handler runs first (adds trauma * 1.2); we then sample.
	var peak: Array = [0.0]
	caster.spell_cast.connect(func(_p: Node, _s: Resource) -> void:
		peak[0] = maxf(peak[0], cam._trauma))

	# base cast_trauma 0.15 * 1.2 = 0.18; without the boost it would be 0.15.
	var deadline: int = Time.get_ticks_msec() + 9000
	while Time.get_ticks_msec() < deadline and peak[0] < 0.175:
		await process_frame
	_ck(peak[0] >= 0.175,
		"base fireball fire shake amplified +20%% (peak trauma %.3f >= 0.175, base 0.15)" % peak[0])

	if _fails == 0:
		print("FIRE SHAKE TEST: ALL PASS")
		quit(0)
	else:
		print("FIRE SHAKE TEST: %d FAILURE(S)" % _fails)
		quit(1)
