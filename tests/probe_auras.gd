## probe_auras.gd — verifies the PARTICLE OVERHAUL wiring (presentation only):
##   • MOVEMENT TRAILS (the 'Trails' cosmetic): a HOVERING skin that's moving emits the hover trail
##     (motes) and NOT the dust; a WALKING skin that's moving emits the dust and NOT the hover trail;
##     idle emits neither.
##   • The green BOON aura lights while a defense buff is active; set_defense_buff_active() toggles it.
##   • set_trail() swaps the active trail emitter by movement_type (the cosmetic seam).
## Run: <godot> --headless --path . -s res://tests/probe_auras.gd
extends SceneTree

var _fails: int = 0


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _init() -> void:
	_run()


func _spawn(hover: bool) -> Node:
	var gs: Node = root.get_node_or_null("GameSettings")
	if gs != null:
		gs.set(&"hover_mode", hover)  # read in the animator's _ready
	var wiz: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz)
	await process_frame
	if "local_tick_driver_enabled" in wiz:
		wiz.local_tick_driver_enabled = false
	return wiz


## Drive visible horizontal motion so the animator reads speed > the trail threshold (it derives speed
## from the rig's X delta per frame; the VisualBridge owns X but isn't ticking here, so we move it).
func _move(rig: Node3D, frames: int) -> void:
	for i in frames:
		rig.position.x += 0.3
		await process_frame


func _run() -> void:
	await process_frame

	# ===== HOVERING skin =====
	var wiz: Node = await _spawn(true)
	var anim: Node = wiz.get_node_or_null(^"WizardAnimator")
	var rig: Node3D = wiz.get_node_or_null(^"WizardRig")
	var dust: Node = wiz.get_node_or_null(^"WizardRig/DustParticles")
	var trail: Node = wiz.get_node_or_null(^"WizardRig/HoverTrail")
	var buff: Node = wiz.get_node_or_null(^"WizardRig/BuffAura")
	_ck(anim != null and dust != null and trail != null and buff != null, "trail + boon nodes + animator resolved")
	if anim == null or trail == null:
		quit(1)
		return

	await process_frame
	await process_frame
	_ck(not dust.emitting and not trail.emitting, "idle hover skin: no movement trail")

	await _move(rig, 3)
	_ck(trail.emitting, "hover skin MOVING: hover trail (motes) emits")
	_ck(not dust.emitting, "hover skin moving: footstep dust does NOT emit")

	# Boon -> green buff aura (sim driver off, so the boost counter stays > 0).
	var mv: Node = wiz.get_node_or_null(^"Movement")
	mv.apply_timed_boost(100000, SGFixed.from_float(1.5))
	await process_frame
	await process_frame
	_ck(buff.emitting, "boon active: green buff aura emits")
	anim.set_defense_buff_active(false)
	_ck(not buff.emitting, "set_defense_buff_active(false) stops the buff aura")

	# set_trail() cosmetic seam: a HOVER trail swaps the active hover emitter.
	var emitter := CPUParticles3D.new()
	emitter.name = "CustomTrail"
	var ps := PackedScene.new()
	ps.pack(emitter)
	emitter.free()
	var t := TrailResource.new()
	t.id = &"custom_hover"
	t.movement_type = TrailResource.MovementType.HOVER
	t.emitter_scene = ps
	var before: Variant = anim.get(&"_hover_trail_node")
	anim.set_trail(t)
	var after: Variant = anim.get(&"_hover_trail_node")
	_ck(after != null and after != before, "set_trail() swapped the active hover trail to the cosmetic emitter")
	_ck(anim.get(&"_hover_trail_instanced") != null, "set_trail() tracked the instance for re-swap")

	wiz.queue_free()  # free before the walk skin so flipping hover_mode doesn't disturb this one
	await process_frame

	# ===== WALKING skin =====
	var w: Node = await _spawn(false)
	var wrig: Node3D = w.get_node_or_null(^"WizardRig")
	var wdust: Node = w.get_node_or_null(^"WizardRig/DustParticles")
	var wtrail: Node = w.get_node_or_null(^"WizardRig/HoverTrail")
	await _move(wrig, 3)
	_ck(wdust.emitting, "walk skin MOVING: footstep dust emits")
	_ck(not wtrail.emitting, "walk skin moving: hover trail does NOT emit")

	if _fails == 0:
		print("AURA PROBE: ALL PASS")
		quit(0)
	else:
		print("AURA PROBE: %d FAILURE(S)" % _fails)
		quit(1)
