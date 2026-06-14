# manual_bounce_check.gd — THROWAWAY headless stand-in for a manual run of
# test_area.tscn. Loads the real scene, holds the cast_spell action down via
# the Input singleton, then watches the spawned fireball: logs its fixed-point
# Y each physics frame and reports whether it bounced off the wall and came
# back toward the player. Delete after sign-off.
#
# Run with:
#   godot --headless --path . -s res://tests/manual_bounce_check.gd
extends SceneTree

const ONE: int = 65536
const MAX_FRAMES: int = 180  # 3 s @ 60 Hz — plenty for spawn + flight + bounce

var _fireball: Node = null
var _bounces: Array = []
var _min_y: int = 0
var _spawn_y: int = 0
var _frames: int = 0
var _done: bool = false


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/test_area.tscn")
	var area: Node = scene.instantiate()
	root.add_child(area)

	var caster: SpellCasterComponent = area.get_node("Player/SpellCasterComponent")
	caster.spell_cast.connect(_on_spell_cast)

	Input.action_press("cast_spell")
	print("HARNESS: test_area.tscn loaded, holding cast_spell...")


func _on_spell_cast(projectile: Node, _spell: Resource = null) -> void:
	if _fireball != null:
		return  # watch only the first fireball
	Input.action_release("cast_spell")  # one cast is enough
	_fireball = projectile
	_spawn_y = projectile.fixed_position.y
	_min_y = _spawn_y
	var movement: Node = projectile.get_node("ProjectileMovementComponent")
	movement.bounced.connect(_on_bounced)
	print("HARNESS: fireball spawned at fixed y=%d (%.2f units)" % [_spawn_y, _spawn_y / 65536.0])


func _on_bounced(normal_x: int, normal_y: int) -> void:
	var y: int = _fireball.fixed_position.y
	_bounces.append([normal_x, normal_y, y])
	print("HARNESS: BOUNCE at fixed y=%d (%.2f units), normal=(%d, %d) (%.2f, %.2f)" % [
			y, y / 65536.0, normal_x, normal_y, normal_x / 65536.0, normal_y / 65536.0])


func _physics_process(_delta: float) -> bool:
	if _done:
		return true
	_frames += 1

	if _fireball != null:
		var y: int = _fireball.fixed_position.y
		_min_y = mini(_min_y, y)
		if _frames % 10 == 0:
			print("HARNESS: frame %3d fireball fixed y=%d (%.2f units)" % [_frames, y, y / 65536.0])
		# Success: bounced and returned past its spawn point heading +Y.
		if not _bounces.is_empty() and y > _spawn_y:
			return _finish()

	if _frames >= MAX_FRAMES:
		return _finish()
	return false


func _finish() -> bool:
	_done = true
	print("HARNESS: --- summary ---")
	if _fireball == null:
		printerr("HARNESS: FAIL — no fireball was ever cast.")
		quit(1)
		return true
	print("HARNESS: spawn y = %.2f units, closest approach y = %.2f units, bounces = %d" % [
			_spawn_y / 65536.0, _min_y / 65536.0, _bounces.size()])
	var wall_normal_ok: bool = not _bounces.is_empty() \
			and _bounces[0][0] == 0 and _bounces[0][1] == ONE
	var returned: bool = _fireball.fixed_position.y > _spawn_y
	if wall_normal_ok and returned:
		print("HARNESS: PASS — fireball flew down-court, bounced off the wall (normal (0, +1)) and returned.")
		quit(0)
	else:
		printerr("HARNESS: FAIL — bounce off wall not observed (normal_ok=%s, returned=%s)." % [wall_normal_ok, returned])
		quit(1)
	return true
