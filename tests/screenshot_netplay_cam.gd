## screenshot_netplay_cam.gd — Sprint 21 fix: verify the CLIENT camera flip.
## Loads the arena, captures the normal HOST view, then calls the camera's
## set_netplay_view(true, Opponent/WizardRig) to render the CLIENT view (behind
## the red Opponent looking up-court at blue) — no second peer needed. NOT headless.
## Run: <godot> --path . -s res://tests/screenshot_netplay_cam.gd
extends SceneTree


func _init() -> void:
	_run()


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	root.add_child(arena)
	await _wait(0.6)  # let the rigs settle at their baselines (NO freeze — match live)
	var cam: Node = arena.get_node_or_null(^"Camera3D")
	root.get_texture().get_image().save_png("res://tests/_screenshot_netplay_host.png")
	print("PROBE: saved host view")

	# Simulate the CLIENT view via the VISUAL MIRROR: flip every VisualBridge's Z so
	# the red Opponent renders at the near (lit) baseline, and point the AUTHORED
	# camera at it. Reuses all the authored lighting/backdrop.
	var opp_rig: Node3D = arena.get_node_or_null(^"Opponent/WizardRig") as Node3D
	for vb in arena.find_children("*", "VisualBridgeComponent", true, false):
		vb.view_flip_z = true
	if cam != null and cam.has_method(&"set_follow_target"):
		cam.set_follow_target(opp_rig)
		print("PROBE: applied visual mirror (follow opp_rig=%s)" % str(opp_rig))
	else:
		printerr("PROBE: camera has no set_follow_target")
	await _wait(1.0)
	var pl_rig: Node3D = arena.get_node_or_null(^"Player/WizardRig") as Node3D
	print("PROBE: cam.pos=%s cam.rot=%s" % [str(cam.global_position), str(cam.rotation_degrees)])
	print("PROBE: cam.forward=%s" % str(-cam.global_transform.basis.z))
	print("PROBE: opp behind=%s screen=%s" % [str(cam.is_position_behind(opp_rig.global_position)), str(cam.unproject_position(opp_rig.global_position))])
	if pl_rig:
		print("PROBE: ply behind=%s screen=%s" % [str(cam.is_position_behind(pl_rig.global_position)), str(cam.unproject_position(pl_rig.global_position))])
	root.get_texture().get_image().save_png("res://tests/_screenshot_netplay_client.png")
	print("PROBE: saved client (flipped) view")
	quit(0)
