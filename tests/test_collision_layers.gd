## test_collision_layers.gd — Headless regression test for the Sprint 2
## "fireball shoots backwards" hotfix.
##
## Run with:
##   godot --headless --path . -s res://tests/test_collision_layers.gd
##
## ROOT CAUSE UNDER TEST: the editor fails to persist SG Physics 2D layer
## assignments, so all bodies defaulted to layer 1 / mask 1 — a fireball
## spawned overlapping its caster collided with the caster on tick 0 and
## bounce()d its velocity backwards. The fix hardcodes layers/masks in each
## controller's _ready() (see scripts/physics_layers.gd).
##
## Verifies, using the REAL controller scripts (so the hardcoded _ready()
## assignments are what's exercised):
##   1. FireballController/BounceWall/(player-layer body) carry the mandated
##      hardcoded layer/mask values after _ready().
##   2. TICK-0 OVERLAP: a fireball spawned overlapping a Layer 1 (player-layer)
##      body ticks once with NO bounce — velocity sign/values unchanged.
##   3. CONTROL: the same fireball overlapping a Layer 3 BounceWall DOES bounce
##      on the first tick — velocity X reverses sign.
extends SceneTree

const ONE: int = 65536

var _bounce_count: int = 0
var _failures: int = 0


func _initialize() -> void:
	var fireball_script := load("res://scripts/projectiles/fireball_controller.gd")
	var movement_script := load("res://scripts/projectiles/components/projectile_movement_component.gd")
	var wall_script := load("res://scripts/arena/bounce_wall.gd")

	# --- Player-layer stand-in at the origin (Layer 1, like PlayerController's
	# hardcoded _ready() values; a bare SG body avoids PlayerController's
	# component-stack asserts while testing the exact same layer/mask ints). ---
	var player_body := SGStaticBody2D.new()
	player_body.name = "PlayerLayerBody"
	player_body.collision_layer = PhysicsLayers.LAYER_PLAYERS
	player_body.collision_mask = PhysicsLayers.LAYER_WALLS
	var player_shape := SGCollisionShape2D.new()
	var player_rect := SGRectangleShape2D.new()
	player_rect.extents = SGFixed.vector2(16 * ONE, 16 * ONE)
	player_shape.shape = player_rect
	player_body.add_child(player_shape)
	root.add_child(player_body)
	player_body.sync_to_physics_engine()

	# --- BounceWall far away at x = +500 (moved into overlap later) ---
	var wall: SGStaticBody2D = wall_script.new()
	wall.name = "BounceWall"
	var wall_shape := SGCollisionShape2D.new()
	var wall_rect := SGRectangleShape2D.new()
	wall_rect.extents = SGFixed.vector2(16 * ONE, 200 * ONE)
	wall_shape.shape = wall_rect
	wall.add_child(wall_shape)
	root.add_child(wall)
	var wall_pos: SGFixedVector2 = wall.fixed_position
	wall_pos.x = 500 * ONE
	wall_pos.y = 0
	wall.fixed_position = wall_pos
	wall.sync_to_physics_engine()

	# --- FireballController spawned overlapping the player body's left edge ---
	# Player rect spans x [-16, +16]; ball radius 8 at x = -22 spans [-30, -14]:
	# a 2-unit overlap, moving +X into the body — the exact spawn-overlap shape
	# of the original "fireball shoots backwards" bug.
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
	var ball_pos: SGFixedVector2 = fireball.fixed_position
	ball_pos.x = -22 * ONE
	ball_pos.y = 0
	fireball.fixed_position = ball_pos
	fireball.sync_to_physics_engine()
	movement.bounced.connect(_on_bounced)

	# _ready() callbacks (where the hardcoded layers are applied) fire on the
	# first tree iteration — wait one frame.
	await process_frame

	# =================================================================
	# TEST 1 — hardcoded layer/mask values survive into the live bodies
	# =================================================================
	_check(fireball.collision_layer == 2, "fireball collision_layer == 2 (projectiles), got %d" % fireball.collision_layer)
	_check(fireball.collision_mask == 4, "fireball collision_mask == 4 (walls only), got %d" % fireball.collision_mask)
	_check(wall.collision_layer == 4, "wall collision_layer == 4 (walls), got %d" % wall.collision_layer)
	_check(wall.collision_mask == 0, "wall collision_mask == 0 (scans nothing), got %d" % wall.collision_mask)
	_check(player_body.collision_layer == 1, "player-layer body collision_layer == 1, got %d" % player_body.collision_layer)

	# =================================================================
	# TEST 2 — tick-0 overlap with a PLAYER-layer body: NO bounce
	# =================================================================
	fireball.launch(10 * ONE, 0, ONE)  # 10 u/tick toward +X, lossless bounce
	_bounce_count = 0
	fireball._network_process({})
	var m: Dictionary = fireball._save_state()["movement"]
	_check(_bounce_count == 0, "no bounce while overlapping player-layer body (got %d bounces)" % _bounce_count)
	_check(m["vx"] == 10 * ONE, "vx unchanged (still +10 u/t = %d), got %d" % [10 * ONE, m["vx"]])
	_check(m["vx"] > 0, "vx sign still positive (fireball did NOT shoot backwards)")
	_check(m["px"] == -12 * ONE, "fireball moved INTO the player body unimpeded, px == %d, got %d" % [-12 * ONE, m["px"]])

	# =================================================================
	# TEST 3 — control: same overlap against a Layer 3 WALL: bounce DOES occur
	# =================================================================
	# Teleport the fireball into the SAME 2-unit edge overlap against the wall:
	# wall rect spans x [484, 516]; ball radius 8 at x = 478 spans [470, 486].
	# (_load_state teleports the body and calls sync_to_physics_engine().)
	fireball._load_state({
		"tick": 0,
		"movement": {"px": 478 * ONE, "py": 0, "vx": 10 * ONE, "vy": 0, "b": ONE},
	})
	_bounce_count = 0
	fireball._network_process({})
	var m2: Dictionary = fireball._save_state()["movement"]
	_check(_bounce_count == 1, "bounce occurred while overlapping wall (got %d bounces)" % _bounce_count)
	_check(m2["vx"] == -(10 * ONE), "vx reversed by wall bounce (== %d), got %d" % [-(10 * ONE), m2["vx"]])
	_check(m2["vx"] < 0, "vx sign flipped negative against the wall")

	if _failures == 0:
		print("COLLISION LAYER TEST: ALL PASS")
		quit(0)
	else:
		print("COLLISION LAYER TEST: %d FAILURE(S)" % _failures)
		quit(1)


func _on_bounced(_normal_x: int, _normal_y: int) -> void:
	_bounce_count += 1


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)
