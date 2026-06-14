## test_determinism.gd — Headless rollback-determinism smoke test (Sprint 2).
##
## Run with:
##   godot --headless --path . -s res://tests/test_determinism.gd
##
## Builds the projectile stack programmatically (FireballController +
## SGCollisionShape2D circle + ProjectileMovementComponent) against a BounceWall
## (SGStaticBody2D + rectangle), then verifies:
##   1. The terminal-velocity cap clamps an over-cap launch (fixed point).
##   2. A wall bounce occurs and reflects/attenuates velocity deterministically.
##   3. _save_state -> run N ticks -> _load_state -> replay N ticks produces a
##      BIT-IDENTICAL final state dictionary (the rollback contract).
extends SceneTree

const ONE: int = 65536
const TICKS: int = 40

var _bounce_count: int = 0
var _last_normal_x: int = 0
var _failures: int = 0


func _initialize() -> void:
	var fireball_script := load("res://scripts/projectiles/fireball_controller.gd")
	var movement_script := load("res://scripts/projectiles/components/projectile_movement_component.gd")
	var wall_script := load("res://scripts/arena/bounce_wall.gd")

	# --- BounceWall at x = +150 sim units (vertical slab, faces -X) ---
	var wall: SGStaticBody2D = wall_script.new()
	wall.name = "BounceWall"
	var wall_shape := SGCollisionShape2D.new()
	var rect := SGRectangleShape2D.new()
	rect.extents = SGFixed.vector2(10 * ONE, 200 * ONE)  # half-extents
	wall_shape.shape = rect
	wall.add_child(wall_shape)
	root.add_child(wall)
	var wall_pos: SGFixedVector2 = wall.fixed_position
	wall_pos.x = 150 * ONE
	wall_pos.y = 0
	wall.fixed_position = wall_pos
	wall.sync_to_physics_engine()

	# --- FireballController at origin, moving +X ---
	var fireball: SGCharacterBody2D = fireball_script.new()
	fireball.name = "Fireball"
	fireball.local_tick_driver_enabled = false  # we drive ticks manually
	var ball_shape := SGCollisionShape2D.new()
	var circle := SGCircleShape2D.new()
	circle.radius = 8 * ONE
	ball_shape.shape = circle
	fireball.add_child(ball_shape)
	var movement: Node = movement_script.new()
	movement.name = "ProjectileMovementComponent"
	fireball.add_child(movement)
	root.add_child(fireball)
	fireball.sync_to_physics_engine()
	movement.bounced.connect(_on_bounced)

	# _ready() callbacks fire on the first tree iteration, not during
	# _initialize() — wait one frame so components resolve their bodies.
	# (local_tick_driver_enabled is false, so no simulation runs in between.)
	await process_frame

	# =================================================================
	# TEST 1 — terminal velocity cap (default 1600 u/s @ 60 tps)
	# =================================================================
	var cap_fp: int = SGFixed.div(SGFixed.from_float(1600.0), SGFixed.from_int(60))
	fireball.launch(100 * ONE, 0, ONE)  # 100 u/tick, way over cap (~26.67 u/tick)
	fireball._network_process({})
	var capped: Dictionary = fireball._save_state()["movement"]
	_check(capped["vx"] == cap_fp,
		"terminal velocity cap: vx == %d (cap), got %d" % [cap_fp, capped["vx"]])
	_check(capped["vy"] == 0, "terminal velocity cap: vy stays 0, got %d" % capped["vy"])

	# =================================================================
	# TEST 2 + 3 — bounce + save/load/replay bit-identical determinism
	# =================================================================
	# Reset to a clean start: origin, 10 u/tick toward the wall, bounciness 0.75.
	fireball._load_state({
		"tick": 0,
		"movement": {"px": 0, "py": 0, "vx": 10 * ONE, "vy": 0, "b": 49152},
	})
	var s0: Dictionary = fireball._save_state()

	_bounce_count = 0
	for i in range(TICKS):
		fireball._network_process({})
	var s1: Dictionary = fireball._save_state()
	var first_run_bounces: int = _bounce_count

	_check(first_run_bounces >= 1, "bounce occurred (got %d bounces)" % first_run_bounces)
	_check(_last_normal_x == -ONE, "wall normal is (-ONE, 0), got normal_x %d" % _last_normal_x)
	var m1: Dictionary = s1["movement"]
	# v' = bounce(v, n) * 0.75 -> vx flips sign and is scaled: 10 u/t -> -7.5 u/t.
	_check(m1["vx"] == -(10 * ONE) * 3 / 4,
		"reflected+attenuated vx == -7.5 u/t (%d), got %d" % [-(10 * ONE) * 3 / 4, m1["vx"]])
	_check(m1["px"] < 150 * ONE, "fireball ended on the near side of the wall, px %d" % m1["px"])

	# Rollback: restore s0 and replay the exact same ticks.
	fireball._load_state(s0)
	_bounce_count = 0
	for i in range(TICKS):
		fireball._network_process({})
	var s2: Dictionary = fireball._save_state()

	_check(_bounce_count == first_run_bounces,
		"replay bounce count identical (%d vs %d)" % [first_run_bounces, _bounce_count])
	_check(s1 == s2, "replayed state BIT-IDENTICAL to first run")
	_check(str(s1) == str(s2), "stringified states identical")
	_check(s1.hash() == s2.hash(), "state dictionary hashes identical")

	print("--- first-run final state:  ", s1)
	print("--- replayed final state:   ", s2)
	if _failures == 0:
		print("DETERMINISM SMOKE TEST: ALL PASS")
		quit(0)
	else:
		print("DETERMINISM SMOKE TEST: %d FAILURE(S)" % _failures)
		quit(1)


func _on_bounced(normal_x: int, normal_y: int) -> void:
	_bounce_count += 1
	_last_normal_x = normal_x


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)
