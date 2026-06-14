## test_net_handshake.gd — Sprint 21 single-process checks for the multiplayer
## framework. Verifies (without a second instance / live server):
##   1. The re-enabled rollback extension + new autoloads load (SyncManager,
##      NetworkManager) and SyncManager built its default network adaptor.
##   2. The menu StateChart is wired correctly: the code-built chart starts at
##      Main and transitions Main->QuickMatch->Local(LocalChoice)->back->back->Main,
##      driving exactly one visible panel per state.
##   3. NetworkManager exposes the expected API and starts in a clean OFFLINE state.
## The true 2-peer rollback start is covered by tests/run_net_smoke.ps1.
## Run: <godot> --headless --path . -s res://tests/test_net_handshake.gd
extends SceneTree

var _fail := 0


func _init() -> void:
	_run()


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		_fail += 1
		printerr("FAIL: ", msg)


func _visible(menu: Node, state_name: String) -> bool:
	var st: Node = menu._states.get(state_name)
	return st != null and menu._panels.has(st) and menu._panels[st].visible


func _run() -> void:
	await process_frame  # let autoloads wire into /root

	# --- 1. autoloads + rollback extension ---
	var sm: Node = root.get_node_or_null(^"/root/SyncManager")
	_ok(sm != null, "SyncManager autoload present")
	_ok(sm != null and sm.get("network_adaptor") != null, "SyncManager built a network adaptor")
	var nm: Node = root.get_node_or_null(^"/root/NetworkManager")
	_ok(nm != null, "NetworkManager autoload present")
	_ok(nm != null and nm.netplay == false, "NetworkManager starts OFFLINE (netplay false)")
	for m in ["start_offline", "lan_host", "lan_search", "nakama_connect", "notify_scene_loaded", "cancel_lobby"]:
		_ok(nm != null and nm.has_method(m), "NetworkManager.%s exists" % m)

	# --- 2. menu StateChart ---
	var menu: Node = load("res://scenes/ui/menu_flow.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame  # deferred initial-state entry

	for s in ["Main", "QuickMatch", "LocalChoice", "Hosting", "Searching", "Connecting", "OnlineHome", "Inviting", "Handshake"]:
		_ok(menu._states.has(s), "chart has state %s" % s)

	_ok(_visible(menu, "Main"), "initial state = Main panel visible")

	menu._chart.send_event("quick_match")
	await process_frame
	_ok(_visible(menu, "QuickMatch"), "quick_match -> QuickMatch visible")
	_ok(not _visible(menu, "Main"), "Main hidden after leaving it")

	menu._chart.send_event("local")
	await process_frame
	_ok(_visible(menu, "LocalChoice"), "local -> Local/LocalChoice visible")

	menu._chart.send_event("back")
	await process_frame
	_ok(_visible(menu, "QuickMatch"), "back -> QuickMatch visible")

	menu._chart.send_event("back")
	await process_frame
	_ok(_visible(menu, "Main"), "back -> Main visible")

	menu.queue_free()
	await process_frame

	if _fail == 0:
		print("NET HANDSHAKE TEST: ALL PASS")
		quit(0)
	else:
		printerr("NET HANDSHAKE TEST: %d FAILED" % _fail)
		quit(1)
