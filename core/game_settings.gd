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

## EQUIPPED COSMETIC SKIN — the skin id the player last EQUIPPED in the Cosmetics screen, persisted to
## user:// so the title-screen wizard wears it across restarts. PRESENTATION ONLY (no sim / no match
## wiring yet — this drives the MENU wizard only).
var equipped_skin: StringName = &"default_blue"
signal equipped_skin_changed(id: StringName)

## DEBUG OPPONENT SKIN (the Cosmetics "Equip skin for opponent" toggle) — an optional skin id forced
## onto the AI OPPONENT wizard in OFFLINE matches ONLY. Empty = no override (the opponent keeps its
## scene-default red). PRESENTATION ONLY; ignored in netplay (the opponent is a real remote peer there).
var opponent_skin: StringName = &""
signal opponent_skin_changed(id: StringName)

## DEBUG HOVER MODE (the Cosmetics "Hover mode" toggle) — an OPTIONAL alternate wizard locomotion: when
## true the wizards permanently HOVER / fly (see WizardAnimatorComponent) instead of the on-ground run
## bob. PRESENTATION ONLY — a visual animation switch we toggle while testing; never touches the sim.
var hover_mode: bool = false
signal hover_mode_changed(on: bool)

## AI DIFFICULTY (Creative Director) — the OFFLINE opponent's skill tier, chosen on the OFFLINE button's
## 3-tier selector in the menu: 0 = Easy, 1 = Normal (the default / shipped tuning), 2 = Hard.
## AIBrainComponent reads this ONCE in _ready and maps it to a tuning preset (the float→int conversion
## happens there, NOT in the per-tick decision — the determinism rule). OFFLINE matches ONLY (the AI is
## removed in netplay), so this never touches cross-peer sim. Persisted so the last-chosen tier sticks.
var ai_difficulty: int = 1
signal ai_difficulty_changed(tier: int)


func _ready() -> void:
	_apply_desktop_window()
	_load_online()
	_load_cosmetics()


## DESKTOP WINDOW SIZING — presentation only; never touches the deterministic sim.
## The game renders its UI into the WINDOW framebuffer (canvas_items stretch over a
## 1080x1920 base), so the old fixed 486x864 desktop test window forced every menu —
## the Decks builder worst of all — to render at <0.5x and look low-res. On desktop we
## size a 9:16 portrait window to ~92% of the player's screen (capped at the native
## 1080x1920 design res = 1:1 pixels) and centre it, so the UI gets its full pixel
## detail back. The gameplay stays retro regardless: that look is the nearest-filtered
## pixel-art sprites + the world-only dither/scanline shader, NOT a small framebuffer.
## No-op on headless (the test sweep) and on mobile (the device already runs native).
func _apply_desktop_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if OS.has_feature("mobile") or not OS.has_feature("pc"):
		return
	var screen: int = DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	# Claim the full working-area height minus a slim title-bar allowance, so a portrait
	# 9:16 window uses every vertical pixel the monitor offers (capped at the 1920 design
	# height = 1:1). On 1080p this is ~990 tall; on 1440p/4K it scales straight to native.
	var h: int = mini(1920, maxi(480, usable.size.y - 40))
	var w: int = int(round(float(h) * 9.0 / 16.0))
	# Refit by width on the rare ultra-short / narrow screen so we never overrun it.
	if w > int(float(usable.size.x) * 0.96):
		w = int(float(usable.size.x) * 0.96)
		h = int(round(float(w) * 16.0 / 9.0))
	DisplayServer.window_set_size(Vector2i(w, h))
	DisplayServer.window_set_position(usable.position + (usable.size - Vector2i(w, h)) / 2)


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


# =====================================================================
# EQUIPPED COSMETIC SKIN persistence (Cosmetics screen → title-screen wizard)
# =====================================================================
func _load_cosmetics() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_CONFIG_PATH) != OK:
		return  # no saved settings yet — keep the default skin
	equipped_skin = StringName(cfg.get_value("cosmetics", "equipped_skin", String(equipped_skin)))
	opponent_skin = StringName(cfg.get_value("cosmetics", "opponent_skin", String(opponent_skin)))
	hover_mode = bool(cfg.get_value("cosmetics", "hover_mode", hover_mode))
	ai_difficulty = clampi(int(cfg.get_value("gameplay", "ai_difficulty", ai_difficulty)), 0, 2)


## Persist the EQUIPPED skin id (the cosmetics EQUIP button). Survives restarts; drives the menu wizard.
func set_equipped_skin(id: StringName) -> void:
	if equipped_skin == id:
		return
	equipped_skin = id
	var cfg := ConfigFile.new()
	cfg.load(_CONFIG_PATH)  # preserve the other sections
	cfg.set_value("cosmetics", "equipped_skin", String(id))
	cfg.save(_CONFIG_PATH)
	equipped_skin_changed.emit(id)


## Persist the DEBUG opponent skin id (the Cosmetics "Equip skin for opponent" toggle). Drives the AI
## opponent's wizard in OFFLINE matches only (see MatchController._apply_equipped_skin). &"" clears it.
func set_opponent_skin(id: StringName) -> void:
	if opponent_skin == id:
		return
	opponent_skin = id
	var cfg := ConfigFile.new()
	cfg.load(_CONFIG_PATH)  # preserve the other sections
	cfg.set_value("cosmetics", "opponent_skin", String(id))
	cfg.save(_CONFIG_PATH)
	opponent_skin_changed.emit(id)


## Persist the DEBUG hover-mode toggle (the Cosmetics "Hover mode" button). Flips the wizards between the
## on-ground bob and the optional hover/flight animation (presentation only). Survives restarts.
func set_hover_mode(on: bool) -> void:
	if hover_mode == on:
		return
	hover_mode = on
	var cfg := ConfigFile.new()
	cfg.load(_CONFIG_PATH)  # preserve the other sections
	cfg.set_value("cosmetics", "hover_mode", on)
	cfg.save(_CONFIG_PATH)
	hover_mode_changed.emit(on)


## Persist the AI difficulty tier (0 = Easy / 1 = Normal / 2 = Hard) chosen on the OFFLINE 3-tier
## selector. The offline opponent's AIBrainComponent reads ai_difficulty in _ready and maps it to a
## tuning preset. Clamped to the valid range; survives restarts.
func set_ai_difficulty(tier: int) -> void:
	var clamped: int = clampi(tier, 0, 2)
	if ai_difficulty == clamped:
		return
	ai_difficulty = clamped
	var cfg := ConfigFile.new()
	cfg.load(_CONFIG_PATH)  # preserve the other sections
	cfg.set_value("gameplay", "ai_difficulty", clamped)
	cfg.save(_CONFIG_PATH)
	ai_difficulty_changed.emit(clamped)
