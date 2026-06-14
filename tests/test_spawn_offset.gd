## test_spawn_offset.gd — Headless spawn-offset verification (Sprint 2 hotfix).
##
## Run with:
##   godot --headless --path . -s res://tests/test_spawn_offset.gd
##
## Builds a caster (SGCharacterBody2D + SpellCasterComponent) and a programmatic
## fireball PackedScene (FireballController + circle + ProjectileMovementComponent),
## then verifies the _spawn_projectile() offset path end to end:
##   1. tick-0 spawn position == caster position + spawn_offset_y (fixed point,
##      exact int equality — also proves the fixed_position copy/reassign works).
##   2. Editing spawn_offset_y AT RUNTIME (the play-tester's exact action) takes
##      effect on the very next cast — regression test for the stale
##      _spawn_offset_y_fp cache fixed by the spawn_offset_y setter.
##   3. cast_direction_y = -1 flips the offset down-court the other way.
##   4. GLOBAL-space spawn (Sprint 2 hotfix round 2 — the origin-spawn trap):
##      a caster body at LOCAL (0,0) under a TRANSLATED SGFixedNode2D wrapper,
##      with the projectile container a SEPARATE node at a different origin,
##      must still spawn at caster GLOBAL ± offset (exact int equality).
##   5. MOVEMENT-HISTORY invariance (Sprint 2 hotfix round 3 — "walking left
##      inverts the cast"): walk the caster LEFT over several ticks, then cast.
##      Spawn Y and launch velocity Y must be bit-identical to a cast with no
##      movement history (exact int equality, velocity Y sign == cast_direction_y).
##   6. BODY-ROTATION invariance (Sprint 2 hotfix round 3): force the caster
##      body's fixed_rotation to a half turn (fixed-point pi) to emulate the
##      suspected facing-by-rotation bug. The cast must be untouched: spawn
##      global Y == caster global Y + offset * cast_direction_y and velocity Y
##      sign == cast_direction_y — facing may ONLY ever be a visual rig flip
##      (VisualBridgeComponent), never physics rotation.
extends SceneTree

const ONE: int = 65536
const CASTER_X: int = 37 * ONE
const CASTER_Y: int = -500 * ONE

# TEST 5 walk: 8 leftward teleport-steps of 16 sim units each (the sim-level
# footprint of holding LEFT for 8 ticks, without coupling this test to
# MovementComponent — Alpha owns that file).
const WALK_STEPS: int = 8
const WALK_STEP_X: int = 16 * ONE

# TEST 6: a half turn in the SG rotation representation. SGFixedNode2D's
# fixed_rotation is FIXED-POINT RADIANS (64.16): 205887 = round(pi * 65536),
# the same value as the plugin's SGFixed.PI constant. The test reads the
# property back (and cross-checks get_global_fixed_rotation via ClassDB) so a
# representation change in a future plugin update fails loudly here.
const HALF_TURN_FP: int = 205887

# TEST 4 geometry — wrapper translation is the human's exact Inspector value
# (fixed Y = 786432 = 12 sim units); the container origin is deliberately
# somewhere else entirely so a local/global space mix-up cannot pass.
const WRAPPER_X: int = -64 * ONE
const WRAPPER_Y: int = 786432
const CONTAINER_X: int = 200 * ONE
const CONTAINER_Y: int = -300 * ONE

var _failures: int = 0
var _last_projectile: Node = null


func _initialize() -> void:
	var caster_script := load("res://scripts/player/components/spell_caster_component.gd")
	var fireball_script := load("res://scripts/projectiles/fireball_controller.gd")
	var movement_script := load("res://scripts/projectiles/components/projectile_movement_component.gd")
	var spell_script := load("res://resources/spell_resource.gd")

	# --- Programmatic fireball PackedScene (mirrors scenes/fireball.tscn shape,
	# minus visuals; local tick driver OFF so nothing moves between cast+assert) ---
	var template: SGCharacterBody2D = fireball_script.new()
	template.name = "Fireball"
	template.local_tick_driver_enabled = false
	var ball_shape := SGCollisionShape2D.new()
	var circle := SGCircleShape2D.new()
	circle.radius = 8 * ONE
	ball_shape.shape = circle
	template.add_child(ball_shape)
	var movement: Node = movement_script.new()
	movement.name = "ProjectileMovementComponent"
	template.add_child(movement)
	ball_shape.owner = template
	movement.owner = template
	var packed := PackedScene.new()
	packed.pack(template)
	template.free()

	# --- Spell resource (data-only, built in code) ---
	var spell: Resource = spell_script.new()
	spell.display_name = "Test Fireball"
	spell.projectile_scene = packed
	spell.base_speed = 800.0
	spell.bounciness = 1.0
	# Instant cast: these tests assert SPAWN GEOMETRY, not the charge flow —
	# cast_time 0 preserves the press-tick == spawn-tick contract they pin.
	spell.cast_time = 0.0

	# --- Caster body + SpellCasterComponent ---
	var caster := SGCharacterBody2D.new()
	caster.name = "Caster"
	var caster_comp: Node = caster_script.new()
	caster_comp.name = "SpellCasterComponent"
	caster_comp.spell = spell
	caster_comp.cast_direction_y = 1
	caster_comp.spawn_offset_y = 48.0
	caster_comp.cooldown_time = 0.5
	caster_comp.tick_rate = 60
	caster.add_child(caster_comp)
	root.add_child(caster)
	var caster_pos: SGFixedVector2 = caster.fixed_position
	caster_pos.x = CASTER_X
	caster_pos.y = CASTER_Y
	caster.fixed_position = caster_pos
	caster.sync_to_physics_engine()
	caster_comp.spell_cast.connect(_on_spell_cast)

	# _ready() callbacks fire on the first tree iteration, not during
	# _initialize() — wait one frame so the component resolves its body.
	await process_frame

	# =================================================================
	# TEST 1 — tick-0 spawn position = caster + offset (exact fixed point)
	# =================================================================
	caster_comp._network_process({"c": 1})  # InputCommand cast bit held
	_check(_last_projectile != null, "cast spawned a projectile")
	var p1: SGFixedVector2 = _last_projectile.fixed_position
	_check(p1.x == CASTER_X, "spawn x == caster x (%d), got %d" % [CASTER_X, p1.x])
	_check(p1.y == CASTER_Y + 48 * ONE,
		"spawn y == caster_y + 48 (%d), got %d" % [CASTER_Y + 48 * ONE, p1.y])

	# =================================================================
	# TEST 2 — RUNTIME spawn_offset_y edit applies on the next cast
	# (regression: stale _spawn_offset_y_fp cached once in _ready())
	# =================================================================
	caster_comp.spawn_offset_y = 96.0  # what the play-tester does in the Inspector
	_run_empty_ticks(caster_comp, 60)  # let the 0.5 s / 30-tick cooldown elapse
	_last_projectile = null
	caster_comp._network_process({"c": 1})
	_check(_last_projectile != null, "second cast spawned a projectile")
	var p2: SGFixedVector2 = _last_projectile.fixed_position
	_check(p2.y == CASTER_Y + 96 * ONE,
		"runtime-edited offset applied: spawn y == caster_y + 96 (%d), got %d"
			% [CASTER_Y + 96 * ONE, p2.y])

	# =================================================================
	# TEST 3 — cast_direction_y = -1 flips the offset
	# =================================================================
	caster_comp.cast_direction_y = -1
	_run_empty_ticks(caster_comp, 60)
	_last_projectile = null
	caster_comp._network_process({"c": 1})
	_check(_last_projectile != null, "third cast spawned a projectile")
	var p3: SGFixedVector2 = _last_projectile.fixed_position
	_check(p3.y == CASTER_Y - 96 * ONE,
		"direction -1 flips offset: spawn y == caster_y - 96 (%d), got %d"
			% [CASTER_Y - 96 * ONE, p3.y])

	# =================================================================
	# TEST 4 — GLOBAL-space spawn (regression: the origin-spawn trap).
	# The human's exact setup: body at LOCAL (0,0) under a translated
	# SGFixedNode2D wrapper; projectiles parented under a SEPARATE
	# container at a different origin. Pre-fix, the local-space read
	# made caster_y look like 0 and the fireball landed at the
	# container's origin (midfield). Post-fix, the projectile's GLOBAL
	# position must equal caster GLOBAL ± offset, exact int equality.
	# =================================================================
	var wrapper := SGFixedNode2D.new()
	wrapper.name = "Wrapper"
	var wrapper_pos: SGFixedVector2 = wrapper.fixed_position
	wrapper_pos.x = WRAPPER_X
	wrapper_pos.y = WRAPPER_Y
	wrapper.fixed_position = wrapper_pos
	root.add_child(wrapper)

	var offset_container := SGFixedNode2D.new()
	offset_container.name = "OffsetContainer"
	var container_pos: SGFixedVector2 = offset_container.fixed_position
	container_pos.x = CONTAINER_X
	container_pos.y = CONTAINER_Y
	offset_container.fixed_position = container_pos
	root.add_child(offset_container)

	var wrapped_caster := SGCharacterBody2D.new()
	wrapped_caster.name = "WrappedCaster"  # local (0,0) — wrapper holds the translation
	var comp2: Node = caster_script.new()
	comp2.name = "SpellCasterComponent"
	comp2.spell = spell
	comp2.spawn_offset_y = 48.0
	comp2.cooldown_time = 0.5
	comp2.tick_rate = 60
	# cast_direction_y deliberately NOT set: pins the -1 (North/down-court)
	# frame-0 default mandated by the Creative Director.
	wrapped_caster.add_child(comp2)
	wrapper.add_child(wrapped_caster)
	wrapped_caster.sync_to_physics_engine()
	comp2.projectile_container_path = comp2.get_path_to(offset_container)
	comp2.spell_cast.connect(_on_spell_cast)
	await process_frame  # let comp2._ready() resolve its body

	_check(comp2.cast_direction_y == -1,
		"frame-0 default cast_direction_y == -1 (North/down-court), got %d"
			% comp2.cast_direction_y)
	var caster_global: SGFixedVector2 = wrapped_caster.get_global_fixed_position()
	_check(caster_global.x == WRAPPER_X and caster_global.y == WRAPPER_Y,
		"wrapped caster GLOBAL == wrapper translation (%d, %d), got (%d, %d)"
			% [WRAPPER_X, WRAPPER_Y, caster_global.x, caster_global.y])

	_last_projectile = null
	comp2._network_process({"c": 1})
	_check(_last_projectile != null, "wrapped cast spawned a projectile")
	_check(_last_projectile.get_parent() == offset_container,
		"projectile parented under the separate OffsetContainer")
	var p4: SGFixedVector2 = _last_projectile.get_global_fixed_position()
	_check(p4.x == WRAPPER_X,
		"GLOBAL spawn x == caster GLOBAL x (%d), got %d" % [WRAPPER_X, p4.x])
	_check(p4.y == WRAPPER_Y - 48 * ONE,
		"GLOBAL spawn y == caster GLOBAL y - 48 (%d), got %d"
			% [WRAPPER_Y - 48 * ONE, p4.y])
	# The container origin differs from the wrapper's, so a correct global
	# placement REQUIRES a nonzero local<->global conversion — prove it.
	var p4_local: SGFixedVector2 = _last_projectile.fixed_position
	_check(p4_local.x == WRAPPER_X - CONTAINER_X,
		"projectile LOCAL x == global - container origin (%d), got %d"
			% [WRAPPER_X - CONTAINER_X, p4_local.x])
	_check(p4_local.y == WRAPPER_Y - 48 * ONE - CONTAINER_Y,
		"projectile LOCAL y == global - container origin (%d), got %d"
			% [WRAPPER_Y - 48 * ONE - CONTAINER_Y, p4_local.y])

	# =================================================================
	# TEST 5 — MOVEMENT-HISTORY invariance (Sprint 2 hotfix round 3:
	# "walking left inverts the cast trajectory"). Walk the first caster
	# LEFT over several ticks, then cast. The spawn must sit at the
	# caster's NEW position + offset * cast_direction_y, and the launch
	# velocity must be (0, speed_per_tick * cast_direction_y) — EXACT
	# int equality, bit-identical to a cast with no movement history.
	# caster_comp state here: cast_direction_y == -1 (set in TEST 3),
	# spawn_offset_y == 96 (set in TEST 2).
	# =================================================================
	# The exact expression SpellCasterComponent caches in _ready():
	# units/sec -> fixed-point units/tick.
	var speed_per_tick_fp: int = SGFixed.div(SGFixed.from_float(spell.base_speed), SGFixed.from_int(60))

	_run_empty_ticks(caster_comp, 60)  # clear TEST 3's cooldown before walking
	for i in range(WALK_STEPS):
		var walk_pos: SGFixedVector2 = caster.fixed_position
		walk_pos.x -= WALK_STEP_X  # leftward step
		caster.fixed_position = walk_pos
		caster.sync_to_physics_engine()
		caster_comp._network_process({})  # tick mid-walk, cast bit clear
	var walked_pos: SGFixedVector2 = caster.get_global_fixed_position()
	_check(walked_pos.x == CASTER_X - WALK_STEPS * WALK_STEP_X,
		"walk moved the caster left to x = %d, got %d"
			% [CASTER_X - WALK_STEPS * WALK_STEP_X, walked_pos.x])

	_last_projectile = null
	caster_comp._network_process({"c": 1})
	_check(_last_projectile != null, "post-walk cast spawned a projectile")
	var p5: SGFixedVector2 = _last_projectile.get_global_fixed_position()
	_check(p5.x == walked_pos.x,
		"post-walk spawn x tracks the caster (%d), got %d" % [walked_pos.x, p5.x])
	_check(p5.y == walked_pos.y - 96 * ONE,
		"MOVEMENT INVARIANT: post-walk spawn y == caster y + offset*dir (%d), got %d"
			% [walked_pos.y - 96 * ONE, p5.y])
	var v5: Dictionary = _last_projectile._save_state()["movement"]
	_check(int(v5["vx"]) == 0,
		"post-walk launch vx == 0 (no sideways drift), got %d" % int(v5["vx"]))
	_check(int(v5["vy"]) == speed_per_tick_fp * caster_comp.cast_direction_y,
		"MOVEMENT INVARIANT: launch vy == speed_per_tick * dir (%d), got %d"
			% [speed_per_tick_fp * caster_comp.cast_direction_y, int(v5["vy"])])
	_check(signi(int(v5["vy"])) == caster_comp.cast_direction_y,
		"launch vy sign == cast_direction_y (%d)" % caster_comp.cast_direction_y)

	# =================================================================
	# TEST 6 — BODY-ROTATION invariance (Sprint 2 hotfix round 3).
	# Emulate the suspected facing-by-rotation bug: force the wrapped
	# caster body's fixed_rotation to a half turn (fixed-point pi). The
	# cast path must not notice — it reads the body's GLOBAL POSITION
	# only and works in global axis components end to end. comp2 state:
	# cast_direction_y == -1 (default), spawn_offset_y == 48.
	# =================================================================
	_check("fixed_rotation" in wrapped_caster,
		"probe: SGFixedNode2D exposes a fixed_rotation property")
	_check(ClassDB.class_has_method("SGFixedNode2D", "get_global_fixed_rotation"),
		"probe: ClassDB confirms get_global_fixed_rotation exists")
	wrapped_caster.fixed_rotation = HALF_TURN_FP
	wrapped_caster.sync_to_physics_engine()
	_check(wrapped_caster.fixed_rotation == HALF_TURN_FP,
		"half-turn rotation applied: fixed_rotation == %d, got %d"
			% [HALF_TURN_FP, wrapped_caster.fixed_rotation])
	_check(wrapped_caster.get_global_fixed_rotation() == HALF_TURN_FP,
		"global rotation reads back the half turn (wrapper unrotated)")
	var rotated_global: SGFixedVector2 = wrapped_caster.get_global_fixed_position()
	_check(rotated_global.x == WRAPPER_X and rotated_global.y == WRAPPER_Y,
		"rotating the body does NOT move its own global origin (%d, %d), got (%d, %d)"
			% [WRAPPER_X, WRAPPER_Y, rotated_global.x, rotated_global.y])

	_run_empty_ticks(comp2, 60)  # clear TEST 4's cooldown
	_last_projectile = null
	comp2._network_process({"c": 1})
	_check(_last_projectile != null, "rotated-body cast spawned a projectile")
	var p6: SGFixedVector2 = _last_projectile.get_global_fixed_position()
	_check(p6.x == WRAPPER_X,
		"ROTATION INVARIANT: spawn global x == caster global x (%d), got %d"
			% [WRAPPER_X, p6.x])
	_check(p6.y == WRAPPER_Y - 48 * ONE,
		"ROTATION INVARIANT: spawn global y == caster global y + offset*dir (%d), got %d"
			% [WRAPPER_Y - 48 * ONE, p6.y])
	var v6: Dictionary = _last_projectile._save_state()["movement"]
	_check(int(v6["vx"]) == 0,
		"rotated-body launch vx == 0, got %d" % int(v6["vx"]))
	_check(int(v6["vy"]) == speed_per_tick_fp * comp2.cast_direction_y,
		"ROTATION INVARIANT: launch vy == speed_per_tick * dir (%d), got %d"
			% [speed_per_tick_fp * comp2.cast_direction_y, int(v6["vy"])])
	_check(signi(int(v6["vy"])) == comp2.cast_direction_y,
		"launch vy sign == cast_direction_y (%d)" % comp2.cast_direction_y)

	if _failures == 0:
		print("SPAWN OFFSET TEST: ALL PASS")
		quit(0)
	else:
		print("SPAWN OFFSET TEST: %d FAILURE(S)" % _failures)
		quit(1)


func _on_spell_cast(projectile: Node, _spell: Resource = null) -> void:
	_last_projectile = projectile


## Advances the caster's cooldown with the canonical empty input (no cast bit).
func _run_empty_ticks(caster_comp: Node, ticks: int) -> void:
	for i in range(ticks):
		caster_comp._network_process({})


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)
