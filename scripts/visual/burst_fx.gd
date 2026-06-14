## burst_fx.gd — One-shot particle bursts (impact feedback).
##
## PURE VISUAL helper: spawns a self-freeing CPUParticles3D burst at a world
## position with a dominant DIRECTION — the "water-balloon" read where the
## spray carries the projectile's momentum instead of puffing out evenly.
## Used by FireballController (wizard hits, fire-colored, along the ball's
## velocity) and BarrierController (shield intercepts, shield-colored,
## sprayed back off the wall face).
class_name BurstFX
extends Object


## Spawns the burst under [param parent] (any 3D-scene node).
##  - dir: dominant world direction (normalized inside; ZERO = radial puff).
##  - speed: mean particle speed (m/s) — pass the projectile's visual speed
##    so the spray genuinely carries its momentum.
# Shared mesh cache (lag-spike fix): building a NEW material per burst made
# the renderer compile fresh pipelines mid-fight — exactly at the slow-mo
# exit when the stack resolves. One mesh+material per (color,size) reuses
# compiled state forever.
static var _mesh_cache: Dictionary = {}


static func _cached_mesh(color: Color, particle_scale: float) -> QuadMesh:
	var key: String = "%s_%.3f" % [color.to_html(), particle_scale]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var quad := QuadMesh.new()
	quad.size = Vector2(particle_scale, particle_scale)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = color
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	_mesh_cache[key] = quad
	return quad


static func spawn(parent: Node, pos: Vector3, dir: Vector3, color: Color,
		amount: int = 24, speed: float = 6.0, particle_scale: float = 0.07,
		spread_degrees: float = 35.0) -> void:
	if parent == null:
		return
	var quad: QuadMesh = _cached_mesh(color, particle_scale)

	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.emitting = true
	burst.explosiveness = 1.0
	burst.amount = amount
	burst.lifetime = 0.55
	burst.mesh = quad
	burst.color = color
	burst.spread = spread_degrees if dir.length() > 0.01 else 180.0
	burst.direction = dir.normalized() if dir.length() > 0.01 else Vector3.UP
	burst.gravity = Vector3(0, -3.5, 0)
	burst.initial_velocity_min = speed * 0.45
	burst.initial_velocity_max = speed * 1.1
	burst.scale_amount_min = 0.5
	burst.scale_amount_max = 1.2
	burst.position = pos
	parent.add_child(burst)
	burst.finished.connect(burst.queue_free)


## WALL PULSE (the invisible side barriers): a subtle low-opacity quad that
## blooms and fades at the impact point, oriented to face into the court —
## the global retro lens pixelates it for free. Rotation is script-applied
## (graveyard rule: never hand-author rotated transforms).
static var _pulse_template: StandardMaterial3D = null


static func spawn_wall_pulse(parent: Node, pos: Vector3, normal_sign: int) -> void:
	if parent == null:
		return
	# The pulse tweens its material's alpha, so each needs its OWN material —
	# but duplicating a cached template shares the compiled shader (no
	# mid-fight pipeline hitch).
	if _pulse_template == null:
		_pulse_template = StandardMaterial3D.new()
		_pulse_template.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_pulse_template.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_pulse_template.albedo_color = Color(0.6, 0.85, 1.0, 0.2)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat: StandardMaterial3D = _pulse_template.duplicate()
	quad.material = mat

	var pulse := MeshInstance3D.new()
	pulse.mesh = quad
	parent.add_child(pulse)
	pulse.global_position = Vector3(pos.x, maxf(0.6, pos.y), pos.z)
	# Quad faces +Z by default; yaw 90° x sign turns it to face across X
	# (into the court, away from the struck side wall).
	pulse.rotation.y = (PI / 2.0) * float(normal_sign)
	pulse.scale = Vector3.ONE * 0.5

	var tw: Tween = pulse.create_tween()
	tw.set_parallel(true)
	tw.tween_property(pulse, "scale", Vector3.ONE * 2.3, 0.45) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(pulse.queue_free)
