## test_match_smoke.gd — Sprint 3 end-to-end smoke test (headless).
##
## Boots the REAL match arena (scenes/match_arena.tscn) and lets it run on the
## wall clock. The AI opponent needs no input devices, so this exercises the
## full loop unattended: AI brain -> input pipeline -> caster -> fireball
## spawn -> lifespan expiry. Also verifies the Stack rules:
##   - the BASE fireball is NOT a card: casting it must NOT open the Stack
##     window or dilate time (Creative Director directive).
##   - TheStack window opens/closes as pure STATE — Sprint 23 batch 3 removed its time-dilation
##     (slow-mo is reserved for shield reflects + player damage), so time stays at 1.0 throughout.
##
## Run: <godot> --headless --path . -s res://tests/test_match_smoke.gd
extends SceneTree

var _failures: int = 0
var _opened: int = 0
var _saw_projectile: bool = false
var _min_time_scale: float = 1.0


func _check(ok: bool, label: String) -> void:
	if ok:
		print("PASS: ", label)
	else:
		print("FAIL: ", label)
		_failures += 1


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	var stack: Node = root.get_node_or_null("TheStack")
	_check(stack != null, "TheStack autoload present")

	var packed: PackedScene = load("res://scenes/match_arena.tscn")
	_check(packed != null, "match_arena.tscn loads")
	if packed == null or stack == null:
		quit(1)
		return

	var arena: Node = packed.instantiate()

	# PIN: base-fireball-only rally. The AI now plays CARDS on an interval
	# (cards legitimately open the Stack); disabling card play keeps this
	# suite's "base fireball never dilates time" assertions meaningful.
	# (tests/test_card_system.gd owns the card-path coverage.)
	var ai_brain: Node = arena.get_node_or_null("Opponent/AIBrain")
	_check(ai_brain != null, "Opponent AIBrain present")
	if ai_brain != null:
		ai_brain.card_interval_ticks = 0
		ai_brain.counter_enabled = false

	root.add_child(arena)
	await process_frame

	stack.stack_opened.connect(func(_d: float) -> void: _opened += 1)

	var projectiles: Node = arena.get_node_or_null("Projectiles")
	_check(projectiles != null, "Projectiles container present")

	var player_health: Node = arena.get_node_or_null("Player/Health")
	_check(player_health != null, "Player HealthComponent present")

	# AI first cast lands at tick ~150 (~2.5 s). Track the FIRST fireball
	# instance specifically: it must be freed by its (now doubled) lifespan
	# even though the AI keeps casting (lifespans overlap, the container never
	# fully empties — asserting on a specific instance is the honest check).
	# GOTCHA (cost one false failure already): in Godot 4 a FREED instance
	# compares == null, so guarding the capture with `first_ball == null`
	# silently re-captures a fresh ball each time the old one dies. Use a
	# dedicated bool so the capture happens exactly once.
	#
	# INDEPENDENT AI (Sprint 19): the opponent no longer mirrors the player, so
	# it does NOT auto-aim at the idle player — instead we assert it PATROLS (its
	# X sweeps on its own agenda). Damage-dealing is covered by the card and
	# round-flow suites. 9 s covers a full lifespan plus a patrol swing.
	var opponent: Node = arena.get_node_or_null("Opponent")
	var opp_start_x: int = opponent.get_global_fixed_position().x if opponent != null else 0
	var opp_max_dx: int = 0
	var first_ball: Node = null
	var first_ball_captured: bool = false
	var first_ball_freed: bool = false
	var deadline: int = Time.get_ticks_msec() + 9000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		_min_time_scale = minf(_min_time_scale, Engine.time_scale)
		if opponent != null:
			opp_max_dx = maxi(opp_max_dx, absi(opponent.get_global_fixed_position().x - opp_start_x))
		if projectiles != null and projectiles.get_child_count() > 0:
			_saw_projectile = true
			if not first_ball_captured:
				first_ball_captured = true
				first_ball = projectiles.get_child(0)
		if first_ball_captured and not is_instance_valid(first_ball):
			first_ball_freed = true
		if first_ball_freed and opp_max_dx > SGFixed.from_float(120.0):
			break

	_check(_saw_projectile, "AI cast spawned a projectile into Projectiles (charge cast completed)")
	_check(_opened == 0, "BASE fireball did NOT open the Stack (opened %d times)" % _opened)
	_check(is_equal_approx(_min_time_scale, 1.0), "time never dilated during base-fireball rally (min %.3f)" % _min_time_scale)
	_check(first_ball_freed, "first fireball was freed (lifespan/despawn) while later casts continued")
	_check(opp_max_dx > SGFixed.from_float(120.0),
		"AI moved INDEPENDENTLY — patrolled its court without mirroring the idle player (|dx|=%.0f units)" % (opp_max_dx / 65536.0))

	# Sprint 23 batch 3: the stack window NO LONGER slows time (slow-mo is reserved for shield reflects
	# + player damage). Opening/closing it is pure state — Engine.time_scale stays at 1.0 throughout.
	stack.open_window(0.4)
	await process_frame
	_check(_opened == 1, "direct open_window() opens the Stack")
	_check(is_equal_approx(Engine.time_scale, 1.0), "open_window() does NOT slow time (got %.3f)" % Engine.time_scale)
	stack.close_window()
	await process_frame
	_check(is_equal_approx(Engine.time_scale, 1.0), "close_window() leaves speed at 1.0")

	if _failures == 0:
		print("MATCH SMOKE TEST: ALL PASS")
	else:
		print("MATCH SMOKE TEST: %d FAILURES" % _failures)
	quit(_failures)
