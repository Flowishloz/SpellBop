## game_settings.gd — Player preferences (autoload: GameSettings).
##
## ROLE: the single source of truth for presentation/control preferences.
## PURE PRESENTATION: nothing here touches the deterministic sim — handedness
## mirrors the camera and HUD layout only; the SG2D plane is untouched.
##
## Consumers read the value in _ready() AND connect to the changed signal so
## toggling mid-match re-flows everything live.
extends Node

## Fired whenever left_handed flips.
signal handedness_changed(left_handed: bool)

## LEFT-HANDED MODE (Creative Director): camera over the LEFT shoulder and
## every HUD element mirrored (hand/dash on the left thumb side, health bar
## top-right) — the §6 dual-thumb layout for left-dominant players.
var left_handed: bool = false

## ONLINE SERVER (Creative Director: "paste my host's IP"). The Nakama server the
## ONLINE flow authenticates against. Defaults to the local Docker dev server; a
## pasted host is persisted to user:// so it survives restarts. CONFIG ONLY —
## never touches the deterministic sim.
const _CONFIG_PATH := "user://settings.cfg"
var nakama_host: String = "127.0.0.1"
var nakama_port: int = 7350
var nakama_scheme: String = "http"
signal nakama_server_changed(host: String, port: int, scheme: String)


func _ready() -> void:
	_load_online()


func set_left_handed(value: bool) -> void:
	if left_handed == value:
		return
	left_handed = value
	handedness_changed.emit(left_handed)


## Mirrors an X coordinate across the 1080-wide portrait canvas when in
## left-handed mode (identity otherwise). HUD layout helper.
func mirror_x(x: float) -> float:
	return 1080.0 - x if left_handed else x


# =====================================================================
# ONLINE SERVER persistence + address parsing ("paste my host's IP")
# =====================================================================
func _load_online() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_CONFIG_PATH) != OK:
		return  # no saved settings yet — keep the local-dev defaults
	nakama_host = String(cfg.get_value("online", "host", nakama_host))
	nakama_port = int(cfg.get_value("online", "port", nakama_port))
	nakama_scheme = String(cfg.get_value("online", "scheme", nakama_scheme))


## Persist the server the ONLINE flow should reach. Survives restarts.
func set_nakama_server(host: String, port: int, scheme: String) -> void:
	nakama_host = host
	nakama_port = port
	nakama_scheme = scheme
	var cfg := ConfigFile.new()
	cfg.load(_CONFIG_PATH)  # preserve any other sections
	cfg.set_value("online", "host", host)
	cfg.set_value("online", "port", port)
	cfg.set_value("online", "scheme", scheme)
	cfg.save(_CONFIG_PATH)
	nakama_server_changed.emit(host, port, scheme)


## Parse a pasted address into {host, port, scheme}. Accepts "1.2.3.4",
## "1.2.3.4:7350", "my.host", "https://my.host", "http://1.2.3.4:7350".
## An empty host keeps the current one.
func parse_nakama_address(text: String) -> Dictionary:
	var s := text.strip_edges()
	var scheme := "http"
	if s.contains("://"):
		var parts := s.split("://", false, 1)
		scheme = parts[0].to_lower()
		s = parts[1] if parts.size() > 1 else ""
	var host := s
	var port := 7350
	var colon := s.rfind(":")
	if colon > 0:
		var tail := s.substr(colon + 1)
		if tail.is_valid_int():
			host = s.substr(0, colon)
			port = int(tail)
	host = host.strip_edges()
	if host == "":
		host = nakama_host
	if scheme != "http" and scheme != "https":
		scheme = "http"
	return {"host": host, "port": port, "scheme": scheme}


## Compact text for the input field (omit default port; scheme only if https).
func nakama_address_text() -> String:
	var s := ""
	if nakama_scheme != "http":
		s += nakama_scheme + "://"
	s += nakama_host
	if nakama_port != 7350:
		s += ":" + str(nakama_port)
	return s
