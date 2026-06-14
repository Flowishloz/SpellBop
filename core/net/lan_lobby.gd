## lan_lobby.gd — LAN transport (Sprint 21). Bypasses Nakama entirely.
##
## Two halves:
##   1. DISCOVERY (PacketPeerUDP): the host broadcasts a small JSON beacon on the
##      local network every ~0.5 s; searchers listen and surface a live lobby list.
##   2. CONNECTION (ENetMultiplayerPeer): host = create_server, client =
##      create_client. Once `multiplayer.multiplayer_peer` is assigned,
##      NetworkManager's `multiplayer.peer_connected` handler takes over — this
##      module knows nothing about the rollback handshake.
##
## Loopback note: the beacon is also sent to 127.0.0.1 so two instances on ONE
## machine can discover each other (255.255.255.255 broadcast doesn't reliably
## loop back on localhost).
extends Node

## ENet game port (the actual match connection).
const GAME_PORT := 24545
## UDP discovery/beacon port.
const DISCOVERY_PORT := 24546
const BEACON_INTERVAL_MS := 500
## A discovered lobby is dropped if no beacon arrives for this long.
const LOBBY_TIMEOUT_MS := 2500
const GAME_TAG := "spellbop"

signal status(message: String)
signal failed(reason: String)
signal lobby_list(lobbies: Array)

var _is_host := false
var _searching := false
var _display_name := "Spell Bop host"

var _beacon: PacketPeerUDP = null      ## host: outbound broadcaster
var _listener: PacketPeerUDP = null    ## searcher: inbound listener
var _next_beacon_ms := 0
var _seen: Dictionary = {}             ## ip -> {name, port, last_ms}
var _last_list_emit_ms := 0


# =====================================================================
# HOST
# =====================================================================
func host(display_name: String) -> int:
	_display_name = display_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(GAME_PORT, 1)
	if err != OK:
		emit_signal(&"failed", "create_server failed (port %d busy?)" % GAME_PORT)
		return err
	multiplayer.multiplayer_peer = peer
	_is_host = true
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_next_beacon_ms = 0  # broadcast immediately on first poll
	emit_signal(&"status", "Hosting (LAN) on port %d…" % GAME_PORT)
	return OK


# =====================================================================
# SEARCH
# =====================================================================
func search() -> void:
	_searching = true
	_listener = PacketPeerUDP.new()
	var err := _listener.bind(DISCOVERY_PORT)
	if err != OK:
		emit_signal(&"failed", "Could not listen for lobbies (UDP %d busy?)" % DISCOVERY_PORT)
		_searching = false
		return
	emit_signal(&"status", "Listening for LAN lobbies…")


func join(lobby: Dictionary) -> int:
	return join_direct(String(lobby.get("ip", "127.0.0.1")), int(lobby.get("port", GAME_PORT)))


func join_direct(ip: String, port: int = 0) -> int:
	if port <= 0:
		port = GAME_PORT
	_stop_discovery()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		emit_signal(&"failed", "create_client failed for %s:%d" % [ip, port])
		return err
	multiplayer.multiplayer_peer = peer
	emit_signal(&"status", "Connecting to %s:%d…" % [ip, port])
	return OK


# =====================================================================
# POLL (driven by NetworkManager._process)
# =====================================================================
func poll() -> void:
	if _is_host and _beacon != null:
		var now := Time.get_ticks_msec()
		if now >= _next_beacon_ms:
			_next_beacon_ms = now + BEACON_INTERVAL_MS
			_broadcast_beacon()
	if _searching and _listener != null:
		_drain_listener()


func _broadcast_beacon() -> void:
	var payload := JSON.stringify({
		"game": GAME_TAG,
		"name": _display_name,
		"port": GAME_PORT,
		"ver": 1,
	}).to_utf8_buffer()
	# Subnet broadcast + explicit loopback (same-machine testing).
	_beacon.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_beacon.put_packet(payload)
	_beacon.set_dest_address("127.0.0.1", DISCOVERY_PORT)
	_beacon.put_packet(payload)


func _drain_listener() -> void:
	var changed := false
	while _listener.get_available_packet_count() > 0:
		var bytes := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var data = JSON.parse_string(bytes.get_string_from_utf8())
		if typeof(data) != TYPE_DICTIONARY or data.get("game", "") != GAME_TAG:
			continue
		_seen[ip] = {
			"ip": ip,
			"name": String(data.get("name", ip)),
			"port": int(data.get("port", GAME_PORT)),
			"last_ms": Time.get_ticks_msec(),
		}
		changed = true
	# Expire stale lobbies + emit at most ~4x/sec.
	var now := Time.get_ticks_msec()
	for ip in _seen.keys():
		if now - int(_seen[ip]["last_ms"]) > LOBBY_TIMEOUT_MS:
			_seen.erase(ip)
			changed = true
	if changed and now - _last_list_emit_ms > 250:
		_last_list_emit_ms = now
		emit_signal(&"lobby_list", _seen.values())


# =====================================================================
# lifecycle
# =====================================================================
## Called by NetworkManager when a peer locks in — stop advertising.
func on_peer_locked() -> void:
	_stop_discovery()


func _stop_discovery() -> void:
	_searching = false
	if _beacon != null:
		_beacon.close()
		_beacon = null
	if _listener != null:
		_listener.close()
		_listener = null


func close() -> void:
	_stop_discovery()
