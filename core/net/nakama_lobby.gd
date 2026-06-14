## nakama_lobby.gd — ONLINE transport (Sprint 21), backed by the vendored
## com.heroiclabs.nakama client + NakamaMultiplayerBridge.
##
## Talks to a LOCAL Nakama server (Docker): 127.0.0.1:7350, console :7351, server
## key "defaultkey" — the defaults the brief specified for the dev phase.
##
## Flow: create_client -> authenticate_device -> open socket -> (friends UX) ->
## create/join a match via NakamaMultiplayerBridge. The bridge owns a
## NakamaMultiplayerPeer; the MOMENT we assign it to multiplayer.multiplayer_peer
## the path becomes byte-identical to the LAN transport — NetworkManager's
## multiplayer.peer_connected handler drives the rest. Invites are sent as
## direct-message channel payloads (works against a stock Nakama server, no custom
## server RPC needed).
extends Node

const SERVER_KEY := "defaultkey"
const HOST := "127.0.0.1"
const PORT := 7350
const SCHEME := "http"
const SMOKE_MATCH_NAME := "spellbop-smoke-room"
const INVITE_KEY := "spellbop_invite"          ## DM payload marker
const CHANNEL_DIRECT_MESSAGE := 2              ## Nakama ChannelType.DirectMessage

signal status(message: String)
signal failed(reason: String)
signal connected(my_user_id: String)
signal friends_updated(friends: Array)         ## Array[Dictionary]{id,username,state,online}
signal invite_received(from_name: String, match_id: String)

var _client = null                             ## NakamaClient
var _socket = null                             ## NakamaSocket
var _session = null                            ## NakamaSession
var _bridge: NakamaMultiplayerBridge = null
var _invite_friend_id := ""                    ## pending: DM the match id here on create


# =====================================================================
# CONNECT + AUTH
# =====================================================================
func connect_and_auth() -> void:
	var nk := get_node_or_null(^"/root/Nakama")
	if nk == null:
		emit_signal(&"failed", "Nakama autoload missing")
		return
	_client = nk.create_client(SERVER_KEY, HOST, PORT, SCHEME)
	var device_id := _device_id()
	emit_signal(&"status", "Authenticating (device %s)…" % device_id.substr(0, 12))
	_session = await _client.authenticate_device_async(device_id, null, true)
	if _session == null or (_session.has_method(&"is_exception") and _session.is_exception()):
		emit_signal(&"failed", "Nakama auth failed (is the Docker server up on :7350?)")
		return
	_socket = nk.create_socket_from(_client)
	_socket.received_channel_message.connect(_on_channel_message)
	_socket.received_notification.connect(_on_notification)
	_socket.closed.connect(func() -> void: emit_signal(&"status", "Nakama socket closed"))
	var res = await _socket.connect_async(_session)
	if res != null and res is NakamaAsyncResult and res.is_exception():
		emit_signal(&"failed", "Nakama socket connect failed")
		return
	emit_signal(&"connected", _session.user_id)
	emit_signal(&"status", "Online as %s" % _session.user_id.substr(0, 8))
	refresh_friends()


# =====================================================================
# FRIENDS (search by id / add / accept / list)
# =====================================================================
func refresh_friends() -> void:
	if _client == null or _session == null:
		return
	var list = await _client.list_friends_async(_session, null, 100, null)
	if list == null or (list.has_method(&"is_exception") and list.is_exception()):
		return
	var out: Array = []
	for f in list.friends:
		# state: 0 mutual, 1 outgoing, 2 incoming, 3 blocked
		out.append({
			"id": f.user.id,
			"username": f.user.username,
			"state": f.state,
			"online": f.user.online if "online" in f.user else false,
		})
	emit_signal(&"friends_updated", out)


## [param query] is a Nakama user id (preferred) or username.
func add_friend(query: String) -> void:
	if _client == null or _session == null or query.strip_edges() == "":
		return
	query = query.strip_edges()
	# Try id first, then username (Nakama's add accepts either set).
	var by_id = await _client.add_friends_async(_session, [query], null)
	if by_id != null and by_id.has_method(&"is_exception") and by_id.is_exception():
		await _client.add_friends_async(_session, null, [query])
	emit_signal(&"status", "Friend request sent to %s" % query)
	refresh_friends()


## Accepting an incoming request = adding them back (Nakama mutual-add model).
func accept_friend(user_id: String) -> void:
	if _client == null or _session == null:
		return
	await _client.add_friends_async(_session, [user_id], null)
	emit_signal(&"status", "Friend accepted")
	refresh_friends()


# =====================================================================
# MATCH (host + invite / accept) — funnels into multiplayer.multiplayer_peer
# =====================================================================
func host_and_invite(friend_user_id: String) -> void:
	if _socket == null:
		emit_signal(&"failed", "Not connected to Nakama")
		return
	_invite_friend_id = friend_user_id
	_make_bridge()
	emit_signal(&"status", "Creating private match…")
	_bridge.create_match()


func accept_invite(match_id: String) -> void:
	if _socket == null:
		emit_signal(&"failed", "Not connected to Nakama")
		return
	_make_bridge()
	emit_signal(&"status", "Joining match…")
	_bridge.join_match(match_id)


## Smoke-test rendezvous: both peers join the SAME named match; Nakama makes the
## first one the host and the second the client (atomic create-or-join by name).
func join_smoke_match() -> void:
	if _socket == null:
		emit_signal(&"failed", "Not connected to Nakama")
		return
	_make_bridge()
	emit_signal(&"status", "Joining smoke match…")
	_bridge.join_named_match(SMOKE_MATCH_NAME)


func _make_bridge() -> void:
	_bridge = NakamaMultiplayerBridge.new(_socket)
	multiplayer.multiplayer_peer = _bridge.multiplayer_peer
	_bridge.match_joined.connect(_on_match_joined)
	_bridge.match_join_error.connect(func(err) -> void: emit_signal(&"failed", "Match error: %s" % str(err)))


func _on_match_joined() -> void:
	emit_signal(&"status", "Match joined (%s)" % _bridge.match_id.substr(0, 8))
	# If we created this as a private invite, DM the match id to the friend.
	if _invite_friend_id != "":
		_send_invite(_invite_friend_id, _bridge.match_id)
		_invite_friend_id = ""
	# From here NetworkManager.peer_connected fires when the opponent arrives.


# =====================================================================
# INVITES (direct-message channel — no custom server code required)
# =====================================================================
func _send_invite(friend_user_id: String, match_id: String) -> void:
	var channel = await _socket.join_chat_async(friend_user_id, CHANNEL_DIRECT_MESSAGE, false, false)
	if channel == null or (channel.has_method(&"is_exception") and channel.is_exception()):
		emit_signal(&"status", "Could not open invite channel")
		return
	await _socket.write_chat_message_async(channel.channel_id, {INVITE_KEY: match_id})
	emit_signal(&"status", "Invite sent")


func _on_channel_message(msg) -> void:
	# ApiChannelMessage.content is a JSON string.
	var content = JSON.parse_string(msg.content) if typeof(msg.content) == TYPE_STRING else msg.content
	if typeof(content) == TYPE_DICTIONARY and content.has(INVITE_KEY):
		var from = msg.username if "username" in msg else msg.sender_id
		emit_signal(&"invite_received", String(from), String(content[INVITE_KEY]))


func _on_notification(_n) -> void:
	pass  # reserved for server-pushed invites later


# =====================================================================
# lifecycle
# =====================================================================
func on_peer_locked() -> void:
	pass  # nothing to stop advertising for Nakama


func close() -> void:
	if _bridge != null:
		if _bridge.has_method(&"leave"):
			_bridge.leave()
		_bridge = null
	if _socket != null and _socket.has_method(&"close_async"):
		_socket.close_async()
	_socket = null


# =====================================================================
# device id — distinct per smoke instance (same machine = same user:// dir, so a
# fixed per-role id keeps the two test instances as DIFFERENT Nakama users).
# =====================================================================
func _device_id() -> String:
	for a in OS.get_cmdline_user_args():
		if a == "--net-smoke=online-host":
			return "spellbop-smoke-host"
		if a == "--net-smoke=online-client":
			return "spellbop-smoke-client"
	var path := "user://nakama_device.txt"
	if FileAccess.file_exists(path):
		return FileAccess.get_file_as_string(path).strip_edges()
	var id := "spellbop-%d-%d" % [Time.get_unix_time_from_system(), randi()]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(id)
		f.close()
	return id
