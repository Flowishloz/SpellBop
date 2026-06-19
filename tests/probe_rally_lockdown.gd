## probe_rally_lockdown.gd — verifies the SHIELD-RALLY MOMENT (slow-mo gameplay half):
##   (1) MOVER SIM SLOW: apply_sim_slow scales a projectile's per-tick MOTION (≈30%), burns its TTL, then
##       lapses back to full speed and resets the factor; the slow round-trips through _save_state.
##   (2) CARD LOCK: apply_card_lock gates CASTING (card caster is_card_locked) but NEVER movement (the
##       wizard still moves, is NOT frozen), and round-trips through _save_state ("cl").
##   (3) RALLY GATE: a barrier capture on the FIRST block (reflect 0) leaves strays + hands ALONE; a capture
##       once a RALLY is established (reflect >= rally_min_reflects) crawls every OTHER field projectile and
##       card-locks BOTH wizards — while leaving the receiver free to move.
## Run: <godot> --headless --path . -s res://tests/probe_rally_lockdown.gd
extends SceneTree

var _fails: int = 0


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _find_movement(wiz: Node) -> Node:
	for c in wiz.get_children():
		if c is MovementComponent:
			return c
	return null


## Duck-typed (make_defense_available is unique to the CardCasterComponent) — avoids a type ref so the probe
## doesn't force an early compile of caster scripts before the autoloads register.
func _find_card_caster(wiz: Node) -> Node:
	for c in wiz.get_children():
		if c.has_method(&"make_defense_available"):
			return c
	return null


func _init() -> void:
	_run()


func _place(body: Node, x: int, y: int) -> void:
	body.set_global_fixed_position(SGFixed.vector2(SGFixed.from_int(x), SGFixed.from_int(y)))
	body.sync_to_physics_engine()


func _spawn_wizard() -> Node:
	var wiz: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz)
	return wiz


func _spawn_ball(container: Node) -> Node:
	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	container.add_child(fb)
	return fb


func _run() -> void:
	await process_frame
	var container := Node.new()
	container.name = "Projectiles"
	root.add_child(container)

	# =====================================================================
	# (1) MOVER SIM SLOW — motion scaled, TTL burns, lapses, saves.
	# =====================================================================
	var ball: Node = _spawn_ball(container)
	await process_frame
	_place(ball, 0, 0)
	# 10 units/tick straight down-court (well under terminal): an easy distance to measure.
	var step: int = SGFixed.from_int(10)
	ball.launch(0, step, SGFixed.ONE)

	# FULL-SPEED control tick: the ball advances ~10 units.
	var y0: int = ball.get_global_fixed_position().y
	ball._network_process({})
	var full_step: int = absi(ball.get_global_fixed_position().y - y0)
	_ck(full_step > SGFixed.from_int(9), "CONTROL: free ball advances ~full step (%d)" % full_step)

	# Now SLOW it to ~30% for 2 ticks and measure ONE slowed step (~3 units).
	_place(ball, 0, 0)
	ball.apply_sim_slow(SGFixed.from_float(0.3), 2)
	_ck(int(ball._save_state()["movement"]["ssk"]) == 2, "apply_sim_slow armed the TTL (ssk=2)")
	var y1: int = ball.get_global_fixed_position().y
	ball._network_process({})
	var slow_step: int = absi(ball.get_global_fixed_position().y - y1)
	_ck(slow_step * 2 < full_step, "SLOWED: a slowed step (%d) is far short of full (%d)" % [slow_step, full_step])
	_ck(int(ball._save_state()["movement"]["ssk"]) == 1, "slowed tick burned one TTL (ssk=1)")

	# Burn the last slowed tick; the factor must RESET so the next slow starts clean.
	ball._network_process({})
	_ck(int(ball._save_state()["movement"]["ssk"]) == 0, "TTL lapsed (ssk=0)")
	_ck(int(ball._save_state()["movement"]["ssf"]) == SGFixed.ONE, "slow factor reset to ONE on lapse")

	# Back to full speed once the slow lapsed.
	var y2: int = ball.get_global_fixed_position().y
	ball._network_process({})
	_ck(absi(ball.get_global_fixed_position().y - y2) > SGFixed.from_int(9), "ball back to full speed after lapse")

	# Save/load round-trips an ACTIVE slow.
	ball.apply_sim_slow(SGFixed.from_float(0.3), 4)
	var saved: Dictionary = ball._save_state()
	var ball2: Node = _spawn_ball(container)
	await process_frame
	ball2._load_state(saved)
	_ck(int(ball2._save_state()["movement"]["ssk"]) == 4, "load_state restored the sim slow (ssk=4)")
	ball.queue_free()
	ball2.queue_free()

	# =====================================================================
	# (2) CARD LOCK — gates casting, NOT movement; saves.
	# =====================================================================
	var wiz: Node = _spawn_wizard()
	await process_frame
	if "local_tick_driver_enabled" in wiz:
		wiz.local_tick_driver_enabled = false
	_place(wiz, 0, 0)
	var mv: Node = _find_movement(wiz)
	var caster: Node = _find_card_caster(wiz)
	_ck(mv != null and caster != null, "wizard has Movement + CardCaster")
	if mv == null or caster == null:
		quit(1)
		return

	# Lock via the wizard's public routing (the path the barrier uses).
	wiz.apply_card_lock(3)
	_ck(mv.is_card_locked(), "apply_card_lock arms the lock")
	_ck(not mv.is_frozen(), "card lock is NOT a movement freeze")
	_ck(caster.is_card_locked(), "card caster mirrors the movement card lock (HUD read)")

	# CRUCIAL: a card-locked wizard can STILL MOVE (only the non-blocking receiver gets this lock).
	var mx0: int = wiz.get_global_fixed_position().x
	mv._network_process({InputCommand.KEY_X: 1})
	_ck(wiz.get_global_fixed_position().x > mx0, "card-locked wizard STILL MOVES (receiver can dodge)")
	_ck(int(mv._save_state()["cl"]) >= 1, "save_state carries the card lock (cl=%s)" % str(mv._save_state()["cl"]))

	# Round-trip onto a fresh wizard.
	var st: Dictionary = mv._save_state()
	var wiz_b: Node = _spawn_wizard()
	await process_frame
	var mv_b: Node = _find_movement(wiz_b)
	if mv_b != null:
		mv_b._load_state(st)
	_ck(mv_b != null and mv_b.is_card_locked(), "load_state restores the card lock on a fresh wizard")
	wiz_b.queue_free()

	# Lock lapses when no longer re-pushed (drive a few free ticks).
	for _i in 5:
		mv._network_process({})
	_ck(not mv.is_card_locked(), "card lock lapses once it stops being re-pushed")
	wiz.queue_free()
	await process_frame

	# =====================================================================
	# (3) RALLY GATE — first block leaves strays/hands alone; the rally crawls + locks both.
	# =====================================================================
	var owner: Node = _spawn_wizard()
	var receiver: Node = _spawn_wizard()
	await process_frame
	if "local_tick_driver_enabled" in owner:
		owner.local_tick_driver_enabled = false
	if "local_tick_driver_enabled" in receiver:
		receiver.local_tick_driver_enabled = false
	_place(owner, 0, 0)
	_place(receiver, 0, 400)
	var owner_mv: Node = _find_movement(owner)
	var recv_mv: Node = _find_movement(receiver)

	# --- PHASE A: a FIRST block (reflect 0) — no rally treatment. ---
	_capture_round(container, owner, receiver, 0)
	var strayA: Node = _last_stray
	_ck(strayA != null and int(strayA._save_state()["movement"]["ssk"]) == 0, "FIRST block: stray NOT slowed")
	_ck(not owner_mv.is_card_locked() and not recv_mv.is_card_locked(), "FIRST block: neither hand locked")
	_clear_round()
	await process_frame  # let PHASE A's queue_free'd nodes actually leave the container before PHASE B

	# --- PHASE B: the SECOND reciprocated block (reflect 1) — the rally moment. ---
	_capture_round(container, owner, receiver, 1)
	var strayB: Node = _last_stray
	_ck(strayB != null and int(strayB._save_state()["movement"]["ssk"]) > 0, "RALLY: stray IS slowed")
	_ck(owner_mv.is_card_locked(), "RALLY: deploying owner's hand locks")
	_ck(recv_mv.is_card_locked(), "RALLY: receiving player's hand locks too (both)")
	_ck(not recv_mv.is_frozen(), "RALLY: receiver is card-locked but NOT frozen (can still move)")

	if _fails == 0:
		print("RALLY LOCKDOWN PROBE: ALL PASS")
		quit(0)
	else:
		print("RALLY LOCKDOWN PROBE: %d FAILURE(S)" % _fails)
		quit(1)


# --- rally-round scaffold ------------------------------------------------
var _bar: Node = null
var _ball: Node = null
var _last_stray: Node = null


## Deploys a fresh barrier owned by [param owner], drops a hostile ball (thrown by [param receiver]) in its
## capture band with [param reflects] prior reflects banked, plus a STRAY ball out of band, then ticks the
## barrier once so it captures. After this, _last_stray is the (un-captured) stray for the assertions.
func _capture_round(container: Node, owner: Node, receiver: Node, reflects: int) -> void:
	_bar = load("res://scenes/barrier.tscn").instantiate()
	_bar.local_tick_driver_enabled = false
	container.add_child(_bar)
	# Drift to await process_frame via a deferred tick — but SceneTree probe can't await inside a sync helper;
	# the barrier's _ready ran on add_child, so deploy directly (positions are set fixed-point).
	_place(_bar, 0, 120)
	_bar.deploy(SGFixed.from_int(100), SGFixed.from_int(20), 0, 0)
	_bar.arm_window_of_affect(owner, 1, SGFixed.ONE, 20, SGFixed.ONE, 0, 0)

	_ball = _spawn_ball(container)
	_place(_ball, 0, 60)
	_ball.set_hit_source(receiver)
	for _i in maxi(0, reflects):
		_ball.add_reflect()  # bank prior reflects so get_reflect_count() reads the rally threshold
	_ball.launch(0, -SGFixed.from_int(20), SGFixed.ONE)

	# A STRAY hostile ball, well OUT of the capture band (far in X) so it is never captured — only slowed.
	_last_stray = _spawn_ball(container)
	_place(_last_stray, 300, -100)
	_last_stray.set_hit_source(receiver)
	_last_stray.launch(0, SGFixed.from_int(12), SGFixed.ONE)

	_bar._network_process({})  # CAPTURE tick: grabs the in-band ball + runs the rally lockdown


func _clear_round() -> void:
	if _bar != null:
		_bar.queue_free()
	if _ball != null:
		_ball.queue_free()
	if _last_stray != null:
		_last_stray.queue_free()
	_bar = null
	_ball = null
	_last_stray = null
