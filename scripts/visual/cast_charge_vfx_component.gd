## cast_charge_vfx_component.gd — Mario-Kart-style charge phase VFX.
##
## PURE VISUAL: listens to a caster's charge signals and drives a particles
## node (the "gathering magic" sparks on the wizard rig) through escalating
## phases — like drift-spark colors. Reads signals only — never touches sim
## state. Floats fine.
##
## PHASES (index = charge level from cast_charge_level_changed):
##   0 = igniting (below minimum cast time): faint warm sparks
##   1 = minimum banked (throwable):         orange-red, faster
##   2 = half boost:                          golden, faster still
##   3 = FULL charge (4x, stationary):        white-hot blue, frantic
## Each phase sets particle color, sim speed_scale, and emission intensity
## (initial velocity). Properties are pushed with set() so the component works
## with CPUParticles3D today and degrades gracefully if a property is missing.
##
## SLOW-MO NOTE: CPUParticles3D advance with the scaled frame delta, so the
## sparks inherit The Stack's 10% time dilation automatically (Creative
## Director: "the particle system should adhere to this") — no special casing.
##
## WORKS FOR BOTH CASTERS: SpellCasterComponent (leveled fireball charge) and
## CardCasterComponent (flat card channel — it emits levels too, see its
## header). Point caster_path at the one to visualize; leave it empty to
## auto-find the first SpellCasterComponent sibling.
class_name CastChargeVFXComponent
extends Node

## The particles node to drive (CPUParticles3D/GPUParticles3D on the rig).
@export var particles_path: NodePath

## The caster to listen to. Empty = auto-find a SpellCasterComponent sibling.
@export var caster_path: NodePath

## Particle color per phase (index = charge GAUGE 0-3). Creative Director:
## gauge 1 = YELLOW, gauge 2 = RED, gauge 3 = BLUE (level 0 = a faint warm
## pre-ignition glow before the first gauge banks).
@export var level_colors: Array[Color] = [
	Color(1.0, 0.85, 0.45, 0.7),   # 0 igniting — faint warm pre-glow
	Color(1.0, 0.92, 0.2, 1.0),    # 1 gauge one — YELLOW
	Color(1.0, 0.3, 0.15, 1.0),    # 2 gauge two — RED
	Color(0.3, 0.6, 1.0, 1.0),     # 3 gauge three — BLUE
]

## Particle system speed_scale per phase (sparks churn faster every phase).
@export var level_speed_scales: Array[float] = [1.0, 1.6, 2.4, 3.4]

## Particle initial_velocity_max per phase (sparks fly harder every phase).
@export var level_velocity_max: Array[float] = [1.8, 2.6, 3.4, 4.6]

var _particles: Node


func _ready() -> void:
	_particles = get_node_or_null(particles_path)
	if _particles == null:
		push_warning("CastChargeVFXComponent: particles_path not set/found — VFX inert.")
		return

	var caster: Node = null
	if not caster_path.is_empty():
		caster = get_node_or_null(caster_path)
	else:
		for child in get_parent().get_children():
			if child is SpellCasterComponent:
				caster = child
				break
	if caster == null:
		push_warning("CastChargeVFXComponent: no caster found — VFX inert.")
		return

	caster.cast_charge_started.connect(_on_charge_started)
	caster.cast_charge_canceled.connect(_on_charge_ended)
	caster.spell_cast.connect(_on_spell_cast)
	if caster.has_signal(&"cast_charge_level_changed"):
		caster.cast_charge_level_changed.connect(_on_level_changed)
	_particles.set(&"emitting", false)


func _on_charge_started(_spell: Resource) -> void:
	_apply_level(0)
	_particles.set(&"emitting", true)


func _on_level_changed(level: int) -> void:
	# Level falls back to 0 when the charge is spent or drains out; the
	# started/canceled/cast handlers own emission on/off, so a falling edge
	# just re-bases the look for the next ignition.
	_apply_level(level)


func _on_charge_ended() -> void:
	_particles.set(&"emitting", false)


func _on_spell_cast(_projectile: Node, _spell: Resource) -> void:
	_particles.set(&"emitting", false)


## Pushes one phase's look onto the particles node. set() is a silent no-op
## for properties the node type lacks — CPU/GPU particles both stay safe.
func _apply_level(level: int) -> void:
	var i: int = clampi(level, 0, 3)
	if i < level_colors.size():
		_particles.set(&"color", level_colors[i])
	if i < level_speed_scales.size():
		_particles.set(&"speed_scale", level_speed_scales[i])
	if i < level_velocity_max.size():
		_particles.set(&"initial_velocity_max", level_velocity_max[i])
