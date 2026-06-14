## test_spawn_bounds.gd — regression for "no projectile spawns outside the map"
## (the Icey Retort counter wave bug). Drives the REAL match_arena so the real
## scene-overridden arena bound (400u via player.tscn) and the real card/scene
## colliders apply.
##
## Core invariant at EVERY spawn site: |spawn_centre.x| + object_half_extent_x
## <= arena_half_width_fp — the object's FULL extent stays inside the lane —
## read from the spawned object's ACTUAL collision shape (so a wrong half-extent
## in the fix would still be caught). Aim is asserted to remain a VELOCITY tilt,
## never moved into the spawn position, and mid-lane casts must be untouched.
##
## Run: godot --headless --path . -s res://tests/test_spawn_bounds.gd
extends SceneTree

const ONE: int = 65536

var _fails: int = 0
var _captured: Node = null
var _arena: Node = null
var _player: Node = null
var _card_caster: Node = null
var _spell_caster: Node = null
var _movement: Node = null
var _bound_fp: int = 0
var _player_y_fp: int = 0


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


## Actual X half-extent (fixed-point) of a spawned SG body's collider:
## rectangle extents_x (wave/barrier) or circle radius (balls).
func _half_extent_x_fp(obj: Node) -> int:
	for child in obj.get_children():
		if child is SGCollisionShape2D and child.shape != null:
			var shape = child.shape
			if shape is SGRectangleShape2D:
				return shape.extents_x
			if shape is SGCircleShape2D:
				return shape.radius
	return 0


func _card_of_type(t: int) -> CardResource:
	for slot in [1, 2, 3]:
		var c: CardResource = _card_caster.call(&"_card_for_slot", slot)
		if c != null and c.card_type == t:
			return c
	return null


## Teleport the caster body to a global X (clamped-safe) and let the engine see it.
func _place_caster_x(x_fp: int) -> void:
	_player.set_global_fixed_position(SGFixed.vector2(x_fp, _player_y_fp))
	_player.sync_to_physics_engine()


## Assert the captured object's full extent is inside the bound; returns centre.x.
func _assert_in_bounds(label: String) -> int:
	if not is_instance_valid(_captured):
		_check(false, label + " — nothing spawned")
		return 0
	var pos: SGFixedVector2 = _captured.get_global_fixed_position()
	var ext: int = _half_extent_x_fp(_captured)
	_check(ext > 0, "%s: collider half-extent read (%d fp)" % [label, ext])
	_check(absi(pos.x) + ext <= _bound_fp,
		"%s: |centre.x|(%d) + half(%d) = %d <= bound(%d)"
			% [label, pos.x, ext, absi(pos.x) + ext, _bound_fp])
	return pos.x


func _run() -> void:
	await process_frame
	_arena = load("res://scenes/match_arena.tscn").instantiate()
	root.add_child(_arena)
	for i in 20:
		await process_frame

	_player = _arena.get_node("Player")
	_card_caster = _player.get_node("CardCasterComponent")
	_spell_caster = _player.get_node("SpellCasterComponent")
	_movement = _player.get_node("Movement")
	_card_caster.spell_cast.connect(_on_cast)
	_spell_caster.spell_cast.connect(_on_cast)

	_bound_fp = _movement.arena_half_width_fp()
	_player_y_fp = _player.get_global_fixed_position().y
	_check(_bound_fp == SGFixed.from_float(400.0),
		"arena bound resolved to 400u (%d fp), got %d" % [SGFixed.from_float(400.0), _bound_fp])

	var attack: CardResource = _card_of_type(CardResource.CardType.ATTACK)
	var defense: CardResource = _card_of_type(CardResource.CardType.DEFENSE)
	var counter: CardResource = _card_of_type(CardResource.CardType.COUNTER)
	_check(attack != null and defense != null and counter != null,
		"resolved attack/defense/counter cards from the hand")

	# ============================================================
	# ICEY RETORT (the headline bug) — RIGHT edge then LEFT edge.
	# ============================================================
	_place_caster_x(_bound_fp)            # +400, the right lane edge
	_captured = null
	_card_caster._resolve_counter(counter, 0)
	var cx_r: int = _assert_in_bounds("COUNTER @ +edge (Icey Retort)")
	_check(cx_r < _bound_fp, "COUNTER @ +edge: centre pulled inboard of the raw edge")

	_place_caster_x(-_bound_fp)           # -400, the left lane edge
	_captured = null
	_card_caster._resolve_counter(counter, 0)
	_assert_in_bounds("COUNTER @ -edge (Icey Retort)")

	# ============================================================
	# DEFENSE wall, ATTACK fan, BASE fireball — at the edge.
	# ============================================================
	_place_caster_x(_bound_fp)
	_captured = null
	_card_caster._resolve_defense(defense)
	_assert_in_bounds("DEFENSE wall @ +edge (Gaea's Wall)")

	_place_caster_x(_bound_fp)
	_captured = null
	_card_caster._resolve_attack(attack)
	_assert_in_bounds("ATTACK ball @ +edge (Spark Bolt)")

	_place_caster_x(_bound_fp)
	_captured = null
	_spell_caster._spawn_projectile()
	_assert_in_bounds("BASE fireball @ +edge")

	# ============================================================
	# MID-LANE no-op: clamp must be inert when the object already fits.
	# ============================================================
	_place_caster_x(0)
	_captured = null
	_card_caster._resolve_counter(counter, 0)
	var cx_mid: int = _assert_in_bounds("COUNTER @ centre")
	_check(cx_mid == 0, "COUNTER @ centre: spawn x EXACTLY 0 (clamp inert mid-lane), got %d" % cx_mid)

	# ============================================================
	# AIM PRESERVED: bank aim into the wall, cast at the edge — the spawn
	# is clamped (position) yet the launch keeps the aim tilt (velocity).
	# Compare the edge cast's vx to a mid-lane cast with the same aim: equal.
	# ============================================================
	var aim_vx_mid: int = _aim_cast_vx(0)        # mid-lane, aim banked right
	var aim_vx_edge: int = _aim_cast_vx(_bound_fp)  # at the edge, aim banked right
	_check(aim_vx_mid > 0, "AIM: mid-lane cast tilts vx right (>0), got %d" % aim_vx_mid)
	_check(aim_vx_edge == aim_vx_mid,
		"AIM PRESERVED: edge cast vx == mid-lane vx (%d), got %d — clamping position did NOT disable aim"
			% [aim_vx_mid, aim_vx_edge])

	# ============================================================
	# BARRIER-BREAKER split: both shards stay in bounds despite the ±28 fan.
	# ============================================================
	_test_split(attack)

	if _fails == 0:
		print("SPAWN BOUNDS TEST: ALL PASS")
		quit(0)
	else:
		print("SPAWN BOUNDS TEST: %d FAILURE(S)" % _fails)
		quit(1)


## Banks rightward aim on the mover, casts the base fireball at global x, and
## returns the projectile's launch vx (fixed-point). Also asserts the spawn x
## is clamped in-bounds at the edge.
func _aim_cast_vx(x_fp: int) -> int:
	_place_caster_x(x_fp)
	# Bank max aim by holding RIGHT for the full aim window (body stays clamped
	# at the edge; aim still accumulates on held input).
	for i in 30:
		_movement._network_process({"x": 1})
	_place_caster_x(x_fp)  # re-pin (held-right may have nudged a mid-lane body)
	_captured = null
	_spell_caster._spawn_projectile()
	if not is_instance_valid(_captured):
		_check(false, "AIM cast spawned a projectile @ x=%d" % x_fp)
		return 0
	var pos: SGFixedVector2 = _captured.get_global_fixed_position()
	var ext: int = _half_extent_x_fp(_captured)
	_check(absi(pos.x) + ext <= _bound_fp,
		"AIM cast @ x=%d still in-bounds (|%d|+%d <= %d)" % [x_fp, pos.x, ext, _bound_fp])
	return int(_captured._save_state()["movement"]["vx"])


## Spawn an attack ball at the edge, force a barrier-breaker split, and assert
## both shards' full radius stays inside the lane.
func _test_split(attack: CardResource) -> void:
	if attack.projectile_scene == null:
		return
	var container: Node = _arena.get_node("Projectiles")
	var ball: Node = attack.projectile_scene.instantiate()
	container.add_child(ball)
	ball.set_global_fixed_position(SGFixed.vector2(_bound_fp, _player_y_fp))
	ball.sync_to_physics_engine()
	ball.launch(0, -SGFixed.from_int(10), SGFixed.ONE)
	var before: Array = container.get_children().duplicate()
	if ball.has_method(&"split_on_barrier"):
		ball.split_on_barrier(-1)
	var shards: int = 0
	for child in container.get_children():
		if child in before or not is_instance_valid(child):
			continue
		if not child.has_method(&"get_global_fixed_position"):
			continue
		shards += 1
		var pos: SGFixedVector2 = child.get_global_fixed_position()
		var ext: int = _half_extent_x_fp(child)
		_check(absi(pos.x) + ext <= _bound_fp,
			"SPLIT shard in-bounds (|%d|+%d = %d <= %d)" % [pos.x, ext, absi(pos.x) + ext, _bound_fp])
	_check(shards >= 2, "SPLIT produced both shards (got %d)" % shards)
