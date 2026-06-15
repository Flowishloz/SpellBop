## test_aim.gd — Headless aim-model verification (Mobile-MP B2).
##
## Run with:
##   godot --headless --path . -s res://tests/test_aim.gd
##
## Verifies the NEW unified aim-sector model (joystick-direction aiming): the
## projectile's lateral launch velocity vx is computed from a quantized aim SECTOR
## that rides the synced input (KEY_AIM) for TOUCH, or is derived from the held
## movement direction for KEYBOARD — both on the same [-AIM_SECTORS, +AIM_SECTORS]
## scale. vx = forward_speed x aim_max_fraction x (sector / AIM_SECTORS), pure
## fixed-point (no trig). The touch path is otherwise only verifiable on a device.
##
## Builds a real caster (SGCharacterBody2D + MovementComponent + SpellCasterComponent
## siblings, the same composition as PlayerController) and a programmatic fireball,
## ticks the components in child order (movement first), and asserts the spawned
## ball's vx is EXACTLY the fixed-point value the formula prescribes (int equality).
extends SceneTree

const N: int = 12            # mirrors InputCommand.AIM_SECTORS (asserted below)
const FULL_HOLD: int = 24    # mirrors SpellCasterComponent.aim_full_hold_ticks
const BASE_SPEED: float = 800.0
const TICK_RATE: int = 60
const AIM_MAX_FRACTION: float = 0.5

var _failures: int = 0
var _last_projectile: Node = null
var _caster_comp: Node = null
var _movement: Node = null
var _speed_fp: int = 0


func _initialize() -> void:
	# AIM_SECTORS is the cross-cutting quantization granularity — pin it so a change
	# to the constant fails loudly here (the joystick + casters + this test share it).
	_check(InputCommand.AIM_SECTORS == N,
		"InputCommand.AIM_SECTORS == %d, got %d" % [N, InputCommand.AIM_SECTORS])

	var caster_script := load("res://scripts/player/components/spell_caster_component.gd")
	var movement_script := load("res://scripts/player/components/movement_component.gd")
	var fireball_script := load("res://scripts/projectiles/fireball_controller.gd")
	var pmove_script := load("res://scripts/projectiles/components/projectile_movement_component.gd")
	var spell_script := load("res://resources/spell_resource.gd")

	# --- Programmatic fireball scene (no visuals; idle tick driver so it never moves) ---
	var template: SGCharacterBody2D = fireball_script.new()
	template.name = "Fireball"
	template.local_tick_driver_enabled = false
	var ball_shape := SGCollisionShape2D.new()
	var circle := SGCircleShape2D.new()
	circle.radius = 8 * 65536
	ball_shape.shape = circle
	template.add_child(ball_shape)
	var pmove: Node = pmove_script.new()
	pmove.name = "ProjectileMovementComponent"
	template.add_child(pmove)
	ball_shape.owner = template
	pmove.owner = template
	var packed := PackedScene.new()
	packed.pack(template)
	template.free()

	# --- Spell (data-only, instant cast so the press tick == the spawn tick) ---
	var spell: Resource = spell_script.new()
	spell.display_name = "Test Fireball"
	spell.projectile_scene = packed
	spell.base_speed = BASE_SPEED
	spell.bounciness = 1.0
	spell.cast_time = 0.0

	# --- Caster body with BOTH a MovementComponent and a SpellCasterComponent
	#     (the real PlayerController composition: the caster reads aim from the
	#     sibling MovementComponent). ---
	var body := SGCharacterBody2D.new()
	body.name = "Wizard"
	_movement = movement_script.new()
	_movement.name = "MovementComponent"
	_movement.tick_rate = TICK_RATE
	body.add_child(_movement)
	_caster_comp = caster_script.new()
	_caster_comp.name = "SpellCasterComponent"
	_caster_comp.spell = spell
	_caster_comp.cast_direction_y = -1            # down-court (North)
	_caster_comp.spawn_offset_y = 48.0
	_caster_comp.cooldown_time = 0.5
	_caster_comp.tick_rate = TICK_RATE
	_caster_comp.aim_max_fraction = AIM_MAX_FRACTION
	_caster_comp.aim_full_hold_ticks = FULL_HOLD
	body.add_child(_caster_comp)
	root.add_child(body)
	body.sync_to_physics_engine()
	_caster_comp.spell_cast.connect(_on_spell_cast)

	await process_frame  # _ready() resolves the body + the sibling MovementComponent

	# The per-tick forward speed the caster caches: units/sec -> fixed units/tick.
	_speed_fp = SGFixed.div(SGFixed.from_float(BASE_SPEED), SGFixed.from_int(TICK_RATE))

	# =================================================================
	# TOUCH AIM: KEY_AIM sets the firing angle directly. vx must equal the
	# fixed-point sector formula EXACTLY (int equality), and vy must stay the
	# full down-court speed regardless of aim.
	# =================================================================
	for sector in [N, -N, N / 2, -(N / 2), 3]:
		var vx: int = _cast_with_aim_input({InputCommand.KEY_AIM: sector})
		var want: int = _expected_vx(sector)
		_check(vx == want,
			"touch KEY_AIM=%d -> vx == %d, got %d" % [sector, want, vx])
		_check_vy_full_down()

	# Straight down-court: no aim -> vx exactly 0.
	var vx0: int = _cast_with_aim_input({})
	_check(vx0 == 0, "no aim -> vx == 0, got %d" % vx0)

	# Out-of-range KEY_AIM is clamped to the cone edge (defensive — a peer can only
	# legally send [-N, N], but the sim must never trust unbounded input).
	var vx_over: int = _cast_with_aim_input({InputCommand.KEY_AIM: N + 50})
	_check(vx_over == _expected_vx(N),
		"over-range KEY_AIM clamps to +N: vx == %d, got %d" % [_expected_vx(N), vx_over])

	# =================================================================
	# KEYBOARD PARITY: holding a direction for the full hold derives the SAME
	# top sector (+N), so a full-hold keyboard throw == a full-deflection touch
	# throw — one unified aim representation.
	# =================================================================
	var vx_kb: int = _cast_after_holding(1, FULL_HOLD)   # hold RIGHT for 24 ticks
	_check(vx_kb == _expected_vx(N),
		"keyboard full-hold RIGHT -> vx == touch(+N) == %d, got %d" % [_expected_vx(N), vx_kb])
	var vx_kb_l: int = _cast_after_holding(-1, FULL_HOLD) # hold LEFT for 24 ticks
	_check(vx_kb_l == _expected_vx(-N),
		"keyboard full-hold LEFT -> vx == touch(-N) == %d, got %d" % [_expected_vx(-N), vx_kb_l])
	# Half hold -> half the top sector (the old hold-to-tilt feel, quantized).
	var vx_kb_half: int = _cast_after_holding(1, FULL_HOLD / 2)
	_check(vx_kb_half == _expected_vx(1 * (FULL_HOLD / 2) * N / FULL_HOLD),
		"keyboard half-hold RIGHT -> vx == %d, got %d"
			% [_expected_vx(1 * (FULL_HOLD / 2) * N / FULL_HOLD), vx_kb_half])

	if _failures == 0:
		print("AIM TEST: ALL PASS")
		quit(0)
	else:
		print("AIM TEST: %d FAILURE(S)" % _failures)
		quit(1)


## vx the caster's formula prescribes for an aim sector (mirrors _aim_vx_fp exactly).
func _expected_vx(sector: int) -> int:
	var lateral_fp: int = SGFixed.div(SGFixed.from_int(sector), SGFixed.from_int(N))
	var max_vx_fp: int = SGFixed.mul(_speed_fp, SGFixed.from_float(AIM_MAX_FRACTION))
	return SGFixed.mul(max_vx_fp, lateral_fp)


## Ticks movement then the caster (child order) with [param aim_input] + the cast bit,
## and returns the spawned ball's launch vx. Clears the cooldown first.
func _cast_with_aim_input(aim_input: Dictionary) -> int:
	_run_idle(60)
	var input: Dictionary = aim_input.duplicate()
	input[InputCommand.KEY_CAST] = 1
	_movement._network_process(input)
	_last_projectile = null
	_caster_comp._network_process(input)
	if _last_projectile == null:
		_check(false, "cast spawned a projectile (aim %s)" % str(aim_input))
		return 0
	return int(_last_projectile._save_state()["movement"]["vx"])


## Holds a keyboard direction for [param ticks] (no KEY_AIM), then casts on the next
## tick while still holding, and returns the spawned ball's launch vx.
func _cast_after_holding(dir: int, ticks: int) -> int:
	_run_idle(60)
	for i in range(ticks):
		_movement._network_process({InputCommand.KEY_X: dir})
	var input := {InputCommand.KEY_X: dir, InputCommand.KEY_CAST: 1}
	_movement._network_process(input)
	_last_projectile = null
	_caster_comp._network_process(input)
	if _last_projectile == null:
		_check(false, "hold-cast spawned a projectile (dir %d)" % dir)
		return 0
	return int(_last_projectile._save_state()["movement"]["vx"])


## vy of the last spawned ball must be the full per-tick speed down-court (aim only
## ever tilts vx; the forward component is untouched).
func _check_vy_full_down() -> void:
	if _last_projectile == null:
		return
	var vy: int = int(_last_projectile._save_state()["movement"]["vy"])
	_check(vy == _speed_fp * _caster_comp.cast_direction_y,
		"vy stays full down-court (%d), got %d" % [_speed_fp * _caster_comp.cast_direction_y, vy])


func _run_idle(ticks: int) -> void:
	for i in range(ticks):
		_movement._network_process({})
		_caster_comp._network_process({})


func _on_spell_cast(projectile: Node, _spell: Resource = null) -> void:
	_last_projectile = projectile


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)
