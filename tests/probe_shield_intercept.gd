## probe_shield_intercept.gd — verifies the LAST-MOMENT BLOCK fix: a ball a barrier is capturing /
## about to capture does NOT also damage the barrier's owner. A fast ball is placed so that after one
## move it overlaps the wizard AND sits in the barrier's capture band (the exact last-moment race).
##   INTERCEPTED: barrier owned by the wizard, armed -> the ball deals NO damage.
##   CONTROL:     no barrier -> the same ball DOES damage (normal hits still work).
## Run: <godot> --headless --path . -s res://tests/probe_shield_intercept.gd
extends SceneTree

var _fails: int = 0


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _find_health(wiz: Node) -> Node:
	var h: Node = wiz.get_node_or_null("HealthComponent")
	if h != null:
		return h
	for c in wiz.get_children():
		if c is HealthComponent:
			return c
	return null


func _init() -> void:
	_run()


func _place(body: Node, x: int, y: int) -> void:
	body.set_global_fixed_position(SGFixed.vector2(SGFixed.from_int(x), SGFixed.from_int(y)))
	body.sync_to_physics_engine()


func _run() -> void:
	await process_frame
	var container := Node.new()
	container.name = "Projectiles"
	root.add_child(container)
	var wiz: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz)
	await process_frame
	if "local_tick_driver_enabled" in wiz:
		wiz.local_tick_driver_enabled = false  # freeze the wizard at (0,0)
	_place(wiz, 0, 0)
	var health: Node = _find_health(wiz)
	_ck(health != null, "wizard has a HealthComponent")
	if health == null:
		quit(1)
		return
	var dummy := Node2D.new()
	root.add_child(dummy)  # a non-wizard hit source so the ball CAN hit the wizard
	var hp0: int = health.get_health()

	# --- INTERCEPTED: a fast ball caught by a barrier owned by the wizard deals NO damage ---
	var bar: Node = load("res://scenes/barrier.tscn").instantiate()
	bar.local_tick_driver_enabled = false
	container.add_child(bar)
	await process_frame
	_place(bar, 0, 120)
	bar.deploy(SGFixed.from_int(100), SGFixed.from_int(20), 0, 0)
	bar.arm_window_of_affect(wiz, 1, SGFixed.ONE, 20, SGFixed.ONE, 0, 0)

	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	container.add_child(fb)
	await process_frame
	_place(fb, 0, 50)
	fb.set_hit_source(dummy)
	fb.launch(0, -SGFixed.from_int(56), SGFixed.ONE)  # fast, toward the wizard
	_ck(bar.would_capture(fb), "barrier would_capture() the fast in-band ball")
	_ck(bar.get_owner_body() == wiz, "barrier.get_owner_body() == the wizard")
	_place(wiz, 0, 0)  # re-pin the wizard right before the tick
	fb._network_process({})  # movement + hit scan -> should be intercepted
	_ck(health.get_health() == hp0, "INTERCEPTED: last-moment block dealt NO damage (hp %d -> %d)" % [hp0, health.get_health()])

	# --- CONTROL: the same fast ball with NO barrier present DOES damage ---
	bar.queue_free()
	await process_frame
	var fb2: Node = load("res://scenes/fireball.tscn").instantiate()
	fb2.local_tick_driver_enabled = false
	container.add_child(fb2)
	await process_frame
	_place(fb2, 0, 50)
	fb2.set_hit_source(dummy)
	fb2.launch(0, -SGFixed.from_int(56), SGFixed.ONE)
	_place(wiz, 0, 0)
	fb2._network_process({})
	_ck(health.get_health() < hp0, "CONTROL: ball with NO barrier DID damage (hp %d -> %d)" % [hp0, health.get_health()])

	if _fails == 0:
		print("SHIELD INTERCEPT PROBE: ALL PASS")
		quit(0)
	else:
		print("SHIELD INTERCEPT PROBE: %d FAILURE(S)" % _fails)
		quit(1)
