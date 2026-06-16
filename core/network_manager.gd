## network_manager.gd — the single coordinator for all multiplayer (Sprint 21).
##
## THE ANTI-SPAGHETTI SPINE. The UI (menu_flow.gd) talks ONLY to this autoload;
## it never touches ENet, Nakama, or SyncManager directly. Two transports plug in
## behind a tiny, identical contract:
##
##   - LAN  -> core/net/lan_lobby.gd     (PacketPeerUDP discovery + ENetMultiplayerPeer)
##   - ONLINE -> core/net/nakama_lobby.gd (Nakama auth/friends/invite + NakamaMultiplayerBridge)
##
## Both do exactly ONE structural thing: assign `multiplayer.multiplayer_peer`. From
## that instant the path is byte-identical for both — NetworkManager owns the
## `multiplayer.peer_connected` signal, runs a deterministic scene-load + ready
## handshake, then hands off to core/net/rollback_session.gd which starts the
## delta_rollback SyncManager. Adding a future transport (Steam, etc.) is one new
## module and zero UI changes.
##
## This is an autoload (PROCESS_MODE_ALWAYS) so it survives change_scene_to_file
## and carries net state from the menu into the arena.
extends Node

const LanLobby := preload("res://core/net/lan_lobby.gd")
const NakamaLobby := preload("res://core/net/nakama_lobby.gd")
const RollbackSession := preload("res://core/net/rollback_session.gd")

const MATCH_SCENE := "res://scenes/match_arena.tscn"
const MENU_SCENE := "res://scenes/home_screen.tscn"

enum Transport { OFFLINE, LAN, ONLINE }
enum Role { NONE, HOST, CLIENT }

# --- public state (read by the UI / arena) ---------------------------
var transport: int = Transport.OFFLINE
var role: int = Role.NONE
## True while a NETWORKED match is being set up or played (carried across the
## menu->arena scene change). The arena reads this in _ready().
var netplay: bool = false
## TEMPORARY (Sprint 21): casting/projectile spawns are not yet routed through
## SpawnManager, so they are not rollback-correct. Netplay disables casting this
## sprint; movement is fully deterministic. Removed next sprint.
var netplay_casting_enabled: bool = false
var remote_peer_id: int = 0

# --- signals the UI listens to ---------------------------------------
signal status(message: String)                       ## human-readable status line
signal lan_lobbies(lobbies: Array)                   ## discovered LAN hosts
signal nakama_connected(my_user_id: String)
signal nakama_friends(friends: Array)                ## Array[Dictionary]{id,username,state,online}
signal nakama_invite(from_name: String, match_id: String)
signal peer_joined(peer_id: int)                     ## remote connected (either transport)
signal connection_failed(reason: String)
signal sync_started()                                ## relayed from SyncManager
signal returned_to_menu()

# --- internals -------------------------------------------------------
var _lobby: Node = null                               ## active LanLobby or NakamaLobby
var _session: RefCounted = null
var _scene_ready: Dictionary = {}                     ## peer_id -> true (incl. self)
var _local_loaded: bool = false
var _session_begun: bool = false
var _smoke_mode: String = ""                          ## "host"/"client"/"online-host"/...
var _smoke_done: bool = false
var _smoke_long: bool = false                         ## "-rounds": drive into round 2+ (movement + cards) to repro the freeze


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Unify both transports here: whoever assigns multiplayer_peer, THIS is where
	# "the other player arrived" surfaces.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if SyncManager != null:
		SyncManager.sync_started.connect(_on_sync_started)
		SyncManager.sync_error.connect(_on_sync_error)
	_parse_smoke_args()


func _process(_delta: float) -> void:
	if _lobby != null and _lobby.has_method(&"poll"):
		_lobby.poll()


# =====================================================================
# OFFLINE (dev sandbox) — bypasses ALL network logic, today's Story Mode.
# =====================================================================
func start_offline() -> void:
	_reset_net_state()
	transport = Transport.OFFLINE
	netplay = false
	emit_signal(&"status", "Loading sandbox…")
	get_tree().change_scene_to_file(MATCH_SCENE)


# =====================================================================
# LAN
# =====================================================================
func lan_host(display_name: String = "Spell Bop host") -> void:
	_reset_net_state()
	transport = Transport.LAN
	role = Role.HOST
	_lobby = _make_lobby(LanLobby)
	if _lobby.host(display_name) != OK:
		_fail("Could not start LAN host")
		return
	emit_signal(&"status", "Hosting on the local network — waiting for a player…")


func lan_search() -> void:
	_reset_net_state()
	transport = Transport.LAN
	role = Role.CLIENT
	_lobby = _make_lobby(LanLobby)
	_lobby.search()
	emit_signal(&"status", "Searching the local network…")


## [param lobby] is one entry from the lan_lobbies signal ({ip, port, name}).
func lan_join(lobby: Dictionary) -> void:
	if _lobby == null or transport != Transport.LAN:
		return
	role = Role.CLIENT
	emit_signal(&"status", "Joining %s…" % lobby.get("name", lobby.get("ip", "host")))
	if _lobby.join(lobby) != OK:
		_fail("Could not join that lobby")


## Smoke-test / direct connect (skips UDP discovery).
func lan_join_direct(ip: String, port: int = 0) -> void:
	_reset_net_state()
	transport = Transport.LAN
	role = Role.CLIENT
	_lobby = _make_lobby(LanLobby)
	if _lobby.join_direct(ip, port) != OK:
		_fail("Could not connect to %s" % ip)


# =====================================================================
# ONLINE (Nakama)
# =====================================================================
func nakama_connect() -> void:
	_reset_net_state()
	transport = Transport.ONLINE
	_lobby = _make_lobby(NakamaLobby)
	_lobby.connected.connect(func(uid: String) -> void: emit_signal(&"nakama_connected", uid))
	_lobby.friends_updated.connect(func(fr: Array) -> void: emit_signal(&"nakama_friends", fr))
	_lobby.invite_received.connect(func(from: String, mid: String) -> void: emit_signal(&"nakama_invite", from, mid))
	emit_signal(&"status", "Connecting to Nakama (127.0.0.1:7350)…")
	_lobby.connect_and_auth()


func nakama_refresh_friends() -> void:
	if _is_nakama(): _lobby.refresh_friends()

func nakama_add_friend(query: String) -> void:
	if _is_nakama(): _lobby.add_friend(query)

func nakama_accept_friend(user_id: String) -> void:
	if _is_nakama(): _lobby.accept_friend(user_id)

## Host a private match and invite a friend by user id.
func nakama_host_and_invite(friend_user_id: String) -> void:
	if not _is_nakama(): return
	role = Role.HOST
	emit_signal(&"status", "Creating private match…")
	_lobby.host_and_invite(friend_user_id)

func nakama_accept_invite(match_id: String) -> void:
	if not _is_nakama(): return
	role = Role.CLIENT
	emit_signal(&"status", "Joining private match…")
	_lobby.accept_invite(match_id)


# =====================================================================
# UNIFIED CONNECTION -> DETERMINISTIC HANDSHAKE
# =====================================================================
## Fired on BOTH peers when the other arrives, regardless of transport (ENet
## fires this for the client on the host and for the server on the client;
## NakamaMultiplayerPeer fires it for the other match member).
func _on_peer_connected(peer_id: int) -> void:
	if _session_begun or netplay:
		return  # already handshaking; ignore extra peers (2-player only)
	remote_peer_id = peer_id
	if role == Role.NONE:
		# We assigned the peer as a client (connected_to_server path sets HOST=remote).
		role = Role.CLIENT
	netplay = true
	netplay_casting_enabled = true  # Phase 2c: cards + Stack are rollback-routed (2a/2b)
	if _lobby != null and _lobby.has_method(&"on_peer_locked"):
		_lobby.on_peer_locked()  # e.g. stop the UDP beacon
	emit_signal(&"status", "Opponent connected — loading arena…")
	emit_signal(&"peer_joined", peer_id)
	# Both peers load the SAME arena; the handshake completes there.
	get_tree().change_scene_to_file(MATCH_SCENE)


func _on_connected_to_server() -> void:
	# Client side of ENet: the server is peer 1. peer_connected(1) also fires and
	# drives the handshake; nothing extra needed here besides status.
	emit_signal(&"status", "Connected — loading arena…")


## Called by MatchController._ready() once the arena scene is up (netplay only).
func notify_scene_loaded() -> void:
	if not netplay:
		return
	_local_loaded = true
	_scene_ready[multiplayer.get_unique_id()] = true
	# Tell the other peer we are ready (reliable so it can't be dropped).
	if multiplayer.multiplayer_peer != null and multiplayer.get_peers().size() > 0:
		rpc(&"_remote_scene_ready")
	_try_begin_session()


@rpc("any_peer", "reliable", "call_remote")
func _remote_scene_ready() -> void:
	var from: int = multiplayer.get_remote_sender_id()
	_scene_ready[from] = true
	_try_begin_session()


func _try_begin_session() -> void:
	if _session_begun or not _local_loaded:
		return
	# Need self + every connected peer to have confirmed the scene is loaded.
	if not _scene_ready.get(multiplayer.get_unique_id(), false):
		return
	for pid in multiplayer.get_peers():
		if not _scene_ready.get(pid, false):
			return
	_session_begun = true
	var is_host: bool = multiplayer.is_server()
	_session = RollbackSession.new()
	_session.begin(remote_peer_id, is_host)


func _on_sync_started() -> void:
	emit_signal(&"sync_started")
	emit_signal(&"status", "Rollback active — fight!")
	if _smoke_mode != "":
		print("[NET-SMOKE] sync_started host=", multiplayer.is_server(), " uid=", multiplayer.get_unique_id())
		# BOTH peers hold cast (each fires fireballs) and NEITHER moves, so the straight
		# shots HIT the opposite wizard. The fingerprint verifies projectile SPAWN-rollback
		# determinism AND hit-DAMAGE rollback determinism (identical wizard HEALTH on both
		# peers). Combined with the forced rollbacks (see _run_smoke) this regression-guards
		# the netplay hit-latch desync that caused the playtest "freeze + crash".
		# (cast is pulsed per-tick in _on_smoke_tick — the fireball is release-fire.)
		if SyncManager != null and not SyncManager.tick_finished.is_connected(_on_smoke_tick):
			SyncManager.tick_finished.connect(_on_smoke_tick)


func _on_sync_error(msg: String) -> void:
	push_error("[NetworkManager] SyncManager error: %s" % msg)
	_fail("Rollback sync error: %s" % msg)


# =====================================================================
# TEARDOWN
# =====================================================================
## Tear down any half-open lobby/connection WITHOUT leaving the menu — the menu
## hub calls this when the player backs out of a host/search/connect attempt.
func cancel_lobby() -> void:
	if _lobby == null and multiplayer.multiplayer_peer == null and not netplay:
		return
	_reset_net_state()


func leave_match() -> void:
	_reset_net_state()  # also stops SyncManager + clears peers
	emit_signal(&"returned_to_menu")
	get_tree().change_scene_to_file(MENU_SCENE)


func _reset_net_state() -> void:
	# A rollback session may be live (mid-match disconnect, leave, or a cancelled
	# setup). Stop it and drop the peer so the NEXT match starts from a clean
	# SyncManager — otherwise a stale peer lingers and add_peer can assert.
	if SyncManager != null:
		if SyncManager.started:
			SyncManager.stop()
		SyncManager.clear_peers()
	if _lobby != null:
		if _lobby.has_method(&"close"):
			_lobby.close()
		_lobby.queue_free()
		_lobby = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	transport = Transport.OFFLINE
	role = Role.NONE
	netplay = false
	remote_peer_id = 0
	_scene_ready.clear()
	_local_loaded = false
	_session_begun = false
	_session = null


# =====================================================================
# helpers
# =====================================================================
func _make_lobby(script: GDScript) -> Node:
	var lobby: Node = script.new()
	add_child(lobby)
	if lobby.has_signal(&"status"):
		lobby.status.connect(func(m: String) -> void: emit_signal(&"status", m))
	if lobby.has_signal(&"failed"):
		lobby.failed.connect(_fail)
	if lobby.has_signal(&"lobby_list"):
		lobby.lobby_list.connect(func(l: Array) -> void: emit_signal(&"lan_lobbies", l))
	return lobby


func _is_nakama() -> bool:
	return _lobby != null and transport == Transport.ONLINE


func _on_peer_disconnected(peer_id: int) -> void:
	emit_signal(&"status", "Peer %d left." % peer_id)
	if netplay:
		_fail("Opponent disconnected")


func _on_connection_failed() -> void:
	_fail("Connection failed")


func _on_server_disconnected() -> void:
	_fail("Host closed the match")


func _fail(reason: String) -> void:
	push_warning("[NetworkManager] %s" % reason)
	emit_signal(&"connection_failed", reason)
	_reset_net_state()


# =====================================================================
# smoke-test autopilot (--net-smoke <mode>)
# =====================================================================
func _parse_smoke_args() -> void:
	var mode := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--net-smoke="):
			mode = a.split("=")[1]
		elif a == "--net-smoke":
			mode = "host"  # default; the launcher passes --net-smoke=<mode>
	if mode == "":
		return
	_smoke_mode = mode
	print("[NET-SMOKE] mode=", mode)
	# Defer so autoloads + the first scene exist before we drive the menu.
	_run_smoke.call_deferred()


func _run_smoke() -> void:
	await get_tree().create_timer(0.5).timeout
	# Force VARIABLE-depth rollbacks (random 0..7 per tick, independently per peer — the
	# real-play asymmetric condition). Zero-latency localhost otherwise never rolls back,
	# so without this the smoke can't exercise the spawn/despawn/hit re-sim path where
	# rollback-only bugs hide. Variable depth (not a constant) is what surfaces the
	# despawn-retire-window crash (a detached ball still group-driven) AND the hit-latch
	# desync — a bug here is a crash or a fingerprint mismatch instead of passing silently.
	if SyncManager != null:
		SyncManager.debug_random_rollback_ticks = 8
	# A "-rounds" suffix = the round-2 freeze repro (drive into round 2+ with movement +
	# cards under rollbacks). The transport is the prefix; strip the suffix for the match.
	_smoke_long = _smoke_mode.ends_with("-rounds")
	match _smoke_mode.trim_suffix("-rounds"):
		"host": lan_host("smoke-host")
		"client": lan_join_direct("127.0.0.1")
		"online-host", "online-client":
			# Both join the SAME named match; Nakama picks host vs client.
			nakama_connect()
			await nakama_connected
			_lobby.join_smoke_match()
		_:
			push_error("[NET-SMOKE] unknown mode: %s" % _smoke_mode)


func _on_smoke_tick(is_rollback: bool) -> void:
	if _smoke_done or SyncManager == null:
		return
	var t: int = int(SyncManager.current_tick)
	# Pulse cast deterministically by tick so both peers fire fireballs identically:
	# hold ~40 ticks (past the 0.5 s charge), release ~5 to trigger the release-fire,
	# repeat. Only on FORWARD ticks — rollback re-sims replay BUFFERED input, not the
	# live Input state.
	if not is_rollback and InputMap.has_action(&"cast_spell"):
		if (t % 45) < 40:
			Input.action_press(&"cast_spell")
		else:
			Input.action_release(&"cast_spell")
	# Pulse a CARD too (Phase 2c): stage an attack at ~tick 100 so the StackResolver
	# resolves it on a deterministic tick (+~180) and the spawned bolt is alive at the
	# tick-300 fingerprint — exercises CARD spawn-rollback determinism, not just fireballs.
	# (Press-edge on a forward tick only; rollback re-sims replay the buffered input.)
	if not is_rollback and InputMap.has_action(&"card_slot_1"):
		if t >= 100 and t < 104:
			Input.action_press(&"card_slot_1")
		else:
			Input.action_release(&"card_slot_1")
	# ROUND-2 FREEZE REPRO (--net-smoke=*-rounds): roam so movement + positions exercise the
	# round-flow + rollback paths the LIVE freeze hit (the tick-300 determinism smoke neither
	# moves nor reaches a KO). Both peers move IDENTICALLY by tick, so they stay aligned and
	# the straight shots keep connecting -> HP drains -> KO -> round 2. Forward ticks only.
	if _smoke_long and not is_rollback:
		var go_right: bool = (t % 150) < 75
		Input.action_release(&"move_left" if go_right else &"move_right")
		Input.action_press(&"move_right" if go_right else &"move_left")
		# Stage a card periodically too (more stack churn across the round boundary).
		if InputMap.has_action(&"card_slot_1") and (t % 200) < 4:
			Input.action_press(&"card_slot_1")

	# Progressive markers (long mode): the LAST marker printed before a hang pinpoints the
	# tick/round it froze on (rf=(..rn..) is the round number). Catches the freeze even
	# though a hung peer never reaches the OK line below.
	if _smoke_long and t > 0 and t % 60 == 0:
		print("[NET-SMOKE] mark t=", t, " ", _smoke_fingerprint())

	# Sample at a FIXED sim tick (not a signal count) so both peers fingerprint the SAME
	# tick. The determinism smoke ends at 300; the -rounds repro runs deep into round 2.
	var end_tick: int = 1800 if _smoke_long else 300
	if t >= end_tick:
		_smoke_done = true
		print("[NET-SMOKE] tick=", t, " fp=", _smoke_fingerprint())
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("res://tests/_net_smoke_%s.png" % ("host" if multiplayer.is_server() else "client"))
		print("[NET-SMOKE] OK")


## A deterministic position fingerprint of both wizards (same on both peers).
func _smoke_fingerprint() -> String:
	var arena := get_tree().current_scene
	if arena == null:
		return "<no-scene>"
	var parts: PackedStringArray = []
	for path in ["Player", "Opponent"]:
		var w := arena.get_node_or_null(path)
		if w != null and w.has_method(&"get_global_fixed_position"):
			var p = w.get_global_fixed_position()
			# HEALTH too (Sprint 22 netplay fix): a hit-damage rollback desync diverges
			# the wizards' health between peers — fold it into the deterministic fingerprint.
			var hp: int = -1
			var h := w.get_node_or_null(^"Health")
			if h != null and h.has_method(&"get_health"):
				hp = h.get_health()
			parts.append("%s=(%d,%d,hp%d)" % [path, p.x, p.y, hp])
	# Projectiles (spawn-rollback proof): count + each fireball's fixed position,
	# sorted by node name (deterministic SpawnManager naming) so both peers compare
	# equal byte-for-byte.
	var proj := arena.get_node_or_null(^"Projectiles")
	if proj != null:
		# DESYNC HUNT: filter to ACTUAL sim balls (SG bodies). The Projectiles container also
		# holds transient wall-pulse VFX (BurstFX.spawn_wall_pulse(get_parent(),...) — a Node3D,
		# no get_global_fixed_position), which pollutes a raw get_children().size() count and is
		# NOT in network_sync (so it never hashes). Count + list balls only.
		var balls: Array = []
		for c in proj.get_children():
			if c.has_method(&"get_global_fixed_position"):
				balls.append(c)
		balls.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
		parts.append("nproj=%d" % balls.size())
		for b in balls:
			var p = b.get_global_fixed_position()
			# NAME (deterministic SpawnManager naming — matches the same ball across the two
			# peers' logs) + fixed-point VELOCITY (a side-wall bounce diverges velocity a tick
			# before position) + collision_mask (a rollback that resets the mask shows here).
			var bvx: int = b.get_velocity_x() if b.has_method(&"get_velocity_x") else 0
			var bvy: int = b.get_velocity_y() if b.has_method(&"get_velocity_y") else 0
			var bmask: int = int(b.collision_mask) if "collision_mask" in b else -1
			parts.append("%s(%d,%d|v%d,%d|m%d)" % [b.name, p.x, p.y, bvx, bvy, bmask])
	# DESYNC HUNT: dump BARRIERS (network_sync members with the barrier API). The aimed
	# balls were bouncing off a Barrier stuck at the scene-default (center, layer WALLS=4)
	# — i.e. one whose _network_spawn never repositioned it / set its one-way layer. List
	# each barrier's pos + collision_layer + age so the two peers can be compared.
	var nsync: Array = arena.get_tree().get_nodes_in_group(&"network_sync") if arena.get_tree() != null else []
	var barriers: Array = []
	for n in nsync:
		if n.has_method(&"arm_window_of_affect"):
			barriers.append(n)
	barriers.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
	parts.append("nbar=%d" % barriers.size())
	for bb in barriers:
		var bp = bb.get_global_fixed_position()
		var blayer: int = int(bb.collision_layer) if "collision_layer" in bb else -1
		parts.append("%s(%d,%d|L%d)" % [bb.name, bp.x, bp.y, blayer])
	# Round flow (Sub-phase 3): fold the RoundFlowResolver's deterministic state so the
	# fingerprint proves both peers agree on phase / scores / round number — and, when a
	# KO lands within the smoke (fireballs whittle HP to 0), that the round reset fired on
	# the SAME tick on both peers (a wall-clock round flow would diverge here).
	var rf := arena.get_node_or_null(^"RoundFlowResolver")
	if rf != null and rf.has_method(&"get_phase"):
		# Fold the emerald cadence (ecd/ecnt) too: it decrements every ACTIVE tick, so a
		# desync in the resolver's new emerald save_state keys diverges it here (Phase 3).
		parts.append("rf=(ph%d,ps%d,os%d,rn%d,ecd%d,ecnt%d)" % [rf.get_phase(),
				rf.get_player_score(), rf.get_opponent_score(), rf.get_round_number(),
				rf.get_emerald_countdown(), rf.get_emerald_count()])
	# Pickups (emerald spawn-rollback proof): count + each emerald's fixed position, so an
	# emerald that spawns within the smoke window is asserted byte-identical on both peers.
	var pickups: Array = arena.get_tree().get_nodes_in_group(&"pickups") if arena.get_tree() != null else []
	pickups.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
	parts.append("npick=%d" % pickups.size())
	for pk in pickups:
		if pk.has_method(&"get_global_fixed_position"):
			var pp = pk.get_global_fixed_position()
			parts.append("e(%d,%d)" % [pp.x, pp.y])
	return ", ".join(parts)
