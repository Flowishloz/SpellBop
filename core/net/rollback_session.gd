## rollback_session.gd — the SyncManager half of the UNIFIED handshake (Sprint 21).
##
## This is the ONLY script that drives delta_rollback's start sequence, keeping the
## addon a black box. NetworkManager calls begin() exactly once, AFTER both peers
## have confirmed (via the reliable scene-ready RPC) that the arena scene is loaded
## and both wizards are configured (authority assigned + joined to "network_sync"
## by MatchController._enter_netplay()). Because that readiness barrier is identical
## for LAN and online, this code is transport-agnostic.
##
## The actual cross-peer start is the addon's: the HOST calls SyncManager.start(),
## which RPCs `_remote_start` to the client, waits half-RTT, and fires `sync_started`
## on BOTH peers at a coordinated tick. Nothing here re-implements rollback.
extends RefCounted


## Given the two-peer connection is up and both scenes are loaded, register the
## peer with SyncManager and (host only) kick the synchronized start.
func begin(remote_peer_id: int, is_host: bool) -> void:
	if SyncManager == null:
		push_error("[rollback_session] SyncManager autoload missing")
		return
	# BOTH peers register the other as a rollback peer (ping/RTT + input routing).
	if not SyncManager.has_peer(remote_peer_id):
		SyncManager.add_peer(remote_peer_id)
	# Only the HOST starts; the addon coordinates the client via _remote_start.
	if is_host:
		SyncManager.start()
