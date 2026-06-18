## menu_flow.gd — the Quick Match menu, driven by a godot_state_charts StateChart
## (Sprint 21). Mounted by the home screen over the 3D diorama.
##
## The chart IS the menu's brain; this script only (a) builds the panels in code
## (matching the home-screen convention), (b) shows/hides one panel per state via
## state_entered/state_exited, (c) turns button presses into chart events
## (send_event), and (d) forwards NetworkManager signals back in as events. It
## NEVER touches ENet/Nakama/SyncManager — only the NetworkManager autoload.
##
## Chart:
##   Root
##    ├─ Main          (Story Mode reserved · QUICK MATCH)
##    ├─ QuickMatch     (Offline · Local · Online)
##    ├─ Local          (compound)
##    │   ├─ LocalChoice (Host / Search)
##    │   ├─ Hosting     (broadcasting; waiting)         entry -> NetworkManager.lan_host
##    │   └─ Searching   (live LAN lobby list)           entry -> NetworkManager.lan_search
##    ├─ Online         (compound)
##    │   ├─ Connecting  (Nakama auth)                    entry -> NetworkManager.nakama_connect
##    │   ├─ OnlineHome  (my id · friends · invite)
##    │   └─ Inviting    (waiting for friend)
##    └─ Handshake      ("opponent found — loading…")
extends Control

const StateChart := preload("res://addons/godot_state_charts/state_chart.gd")
const CompoundState := preload("res://addons/godot_state_charts/compound_state.gd")
const AtomicState := preload("res://addons/godot_state_charts/atomic_state.gd")
const Transition := preload("res://addons/godot_state_charts/transition.gd")
const UI_THEME := preload("res://ui/main_theme.tres")
const FROST_SHADER := preload("res://ui/frosted_panel.gdshader")

var _nm: Node                                    ## NetworkManager autoload
var _chart: Node
var _states: Dictionary = {}                     ## name -> state node
var _panels: Dictionary = {}                     ## state node -> panel Control
var _status: Label
var _lan_list: VBoxContainer
var _friend_list: VBoxContainer
var _friend_input: LineEdit
var _server_input: LineEdit
var _my_id_label: Label
var _invite_box: VBoxContainer

# OFFLINE difficulty selector (the 3-tier Easy/Normal/Hard control the OFFLINE button
# reveals — it replaces the old "dev sandbox" straight-to-launch). Built once in _panel_quick.
var _quick_modes: Array[Control] = []            ## OFFLINE / LOCAL / ONLINE (hidden while the tray is open)
var _quick_back: Button                          ## the QuickMatch BACK button (hidden while the tray is open)
var _difficulty_tray: Control                    ## the hidden difficulty panel
var _diff_segments: Array[Button] = []           ## the 3 level stops (0=Easy / 1=Normal / 2=Hard)
var _selected_difficulty: int = 1                ## the highlighted tier (mirrors GameSettings.ai_difficulty)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UI_THEME   # the universal Y2K theme cascades to every panel / button / label below
	# No big container plate (CD: light + minimal) — buttons float as light rounded frosted buttons
	# over the diorama, so the SPELL BOP title art + wizard stay clear above them.
	_nm = get_node_or_null(^"/root/NetworkManager")
	_build_chart()
	_build_panels()
	_wire_network_signals()
	# Add the chart LAST, after panels + signal hookups, so the deferred initial
	# state entry (Main) lands on a fully-wired UI.
	add_child(_chart)


# =====================================================================
# STATE CHART (built in code; paths via get_path_to so depth can't bite us)
# =====================================================================
func _build_chart() -> void:
	_chart = StateChart.new()
	_chart.name = "MenuChart"
	var root := _compound("Root")
	_chart.add_child(root)

	var main := _atomic("Main", root)
	var quick := _atomic("QuickMatch", root)
	var local := _compound("Local"); root.add_child(local)
	var local_choice := _atomic("LocalChoice", local)
	var hosting := _atomic("Hosting", local)
	var searching := _atomic("Searching", local)
	var online := _compound("Online"); root.add_child(online)
	var connecting := _atomic("Connecting", online)
	var online_home := _atomic("OnlineHome", online)
	var inviting := _atomic("Inviting", online)
	var handshake := _atomic("Handshake", root)

	# Initial child for every compound (NodePath relative to the compound).
	root.set("initial_state", root.get_path_to(main))
	local.set("initial_state", local.get_path_to(local_choice))
	online.set("initial_state", online.get_path_to(connecting))

	# Transitions (event -> target). Events bubble leaf->root, so the compound-
	# level peer_joined/failed catch from any of their substates.
	_transition(main, "quick_match", quick)
	_transition(quick, "local", local)
	_transition(quick, "online", online)
	_transition(quick, "back", main)
	_transition(local_choice, "host", hosting)
	_transition(local_choice, "search", searching)
	_transition(local_choice, "back", quick)
	_transition(hosting, "back", quick)
	_transition(searching, "back", quick)
	_transition(local, "peer_joined", handshake)
	_transition(local, "failed", quick)
	_transition(connecting, "online_ready", online_home)
	_transition(connecting, "back", quick)
	_transition(online_home, "inviting", inviting)
	_transition(online_home, "back", quick)
	_transition(inviting, "back", online_home)
	_transition(online, "peer_joined", handshake)
	_transition(online, "failed", quick)

	# State -> action + panel visibility wiring.
	for sname in _states:
		var st: Node = _states[sname]
		st.state_entered.connect(_on_state_entered.bind(st))
		st.state_exited.connect(_on_state_exited.bind(st))


func _compound(nm: String) -> Node:
	var s = CompoundState.new()
	s.name = nm
	_states[nm] = s
	return s


func _atomic(nm: String, parent: Node) -> Node:
	var s = AtomicState.new()
	s.name = nm
	parent.add_child(s)
	_states[nm] = s
	return s


func _transition(from: Node, event: String, to: Node) -> void:
	var t = Transition.new()
	t.event = event
	from.add_child(t)
	t.set("to", t.get_path_to(to))   # depth-proof relative path


func _send(event: String) -> void:
	if _chart != null:
		_chart.send_event(event)


# =====================================================================
# PANELS (one per state)
# =====================================================================
func _build_panels() -> void:
	# Shared status line at the bottom.
	_status = Label.new()
	_status.position = Vector2(60, 1820)
	_status.size = Vector2(960, 60)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override(&"font_size", 30)
	_status.modulate = Color(0.85, 0.9, 1.0)
	add_child(_status)

	_panels[_states["Main"]] = _panel_main()
	_panels[_states["QuickMatch"]] = _panel_quick()
	_panels[_states["LocalChoice"]] = _panel_local_choice()
	_panels[_states["Hosting"]] = _panel_hosting()
	_panels[_states["Searching"]] = _panel_searching()
	_panels[_states["Connecting"]] = _panel_connecting()
	_panels[_states["OnlineHome"]] = _panel_online_home()
	_panels[_states["Inviting"]] = _panel_inviting()
	_panels[_states["Handshake"]] = _panel_handshake()
	for st in _panels:
		_panels[st].visible = false
		add_child(_panels[st])


func _panel_main() -> Control:
	var p := _panel()
	var story := _button(p, "STORY MODE", Vector2(160, 1380), Vector2(760, 96), 38)
	story.disabled = true
	story.tooltip_text = "Single-player campaign — coming soon"
	var quick := _button(p, "QUICK MATCH", Vector2(160, 1488), Vector2(760, 108), 46)
	quick.pressed.connect(func() -> void: _click(); _send("quick_match"))
	var labels := ["DECKS", "COSMETICS", "SHOP"]
	for i in 3:
		var ph := _button(p, labels[i], Vector2(160 + 256.0 * float(i), 1620), Vector2(248, 84), 26)
		if labels[i] == "COSMETICS":
			# ENABLED: opens the 3D Cosmetics / skin-selection scene. It is a whole separate scene
			# (a 3D diorama, not a menu sub-panel), so a plain change_scene — not a StateChart state.
			ph.pressed.connect(func() -> void: _click(); get_tree().change_scene_to_file("res://scenes/cosmetics.tscn"))
		else:
			ph.disabled = true
	return p


func _panel_quick() -> Control:
	var p := _panel()
	_title(p, "QUICK MATCH", 1120)
	# The three mode buttons live in a group we hide while the OFFLINE difficulty tray
	# is open, so the tray takes over that vertical band (no overlap).
	_quick_modes.clear()
	# OFFLINE no longer launches straight into the sandbox — it OPENS the 3-tier AI
	# difficulty selector (Easy / Normal / Hard); picking a tier launches the match.
	var offline := _button(p, "OFFLINE", Vector2(140, 1240), Vector2(800, 120), 40)
	offline.pressed.connect(func() -> void: _click(); _open_difficulty())
	_quick_modes.append(offline)
	var local := _button(p, "LOCAL  ·  same WiFi", Vector2(140, 1380), Vector2(800, 120), 40)
	local.pressed.connect(func() -> void: _click(); _send("local"))
	_quick_modes.append(local)
	var online := _button(p, "ONLINE  ·  Nakama", Vector2(140, 1520), Vector2(800, 120), 40)
	online.pressed.connect(func() -> void: _click(); _send("online"))
	_quick_modes.append(online)
	_quick_back = _back(p, func() -> void: _send("back"))
	# The OFFLINE difficulty tray — built hidden, revealed by the OFFLINE button.
	_difficulty_tray = _build_difficulty_tray(p)
	return p


## Builds the hidden OFFLINE difficulty selector: a "slider"-styled control with three
## FIXED stops (Level 1 / 2 / 3 = Easy / Normal / Hard — the slider is aesthetic, not
## draggable), a PLAY button that launches the offline match at the chosen tier, and a
## BACK that collapses the tray. Occupies the same band as the mode buttons (hidden while open).
func _build_difficulty_tray(parent: Control) -> Control:
	var tray := _panel()
	parent.add_child(tray)
	var head := _label(tray, "SELECT  DIFFICULTY", Vector2(140, 1200), 34)
	head.size = Vector2(800, 50)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# The slider rail behind the three stops (pure decoration — reads as a 3-notch slider).
	var rail := ColorRect.new()
	rail.color = Color(0.55, 0.62, 0.85, 0.32)
	rail.position = Vector2(150, 1346)
	rail.size = Vector2(780, 12)
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tray.add_child(rail)
	# Three FIXED stops along the rail (the big numbers 1/2/3 with the tier name beneath).
	# Clicking one SELECTS it (lights the "handle"); PLAY launches at the selection.
	_diff_segments.clear()
	var names := ["EASY", "NORMAL", "HARD"]
	var seg_w: float = 232.0
	var gap: float = 12.0
	var start_x: float = 540.0 - (seg_w * 3.0 + gap * 2.0) * 0.5   # centred on the 1080-wide canvas
	for i in 3:
		var sx: float = start_x + float(i) * (seg_w + gap)
		var seg := _button(tray, str(i + 1), Vector2(sx, 1290), Vector2(seg_w, 120), 48)
		seg.pressed.connect(func() -> void: _click(); _select_difficulty(i))
		_diff_segments.append(seg)
		var nm := _label(tray, names[i], Vector2(sx, 1422), 24)
		nm.size = Vector2(seg_w, 32)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# PLAY — launch the offline match at the selected tier.
	var play := _button(tray, "PLAY  ▶", Vector2(300, 1490), Vector2(480, 116), 46)
	play.pressed.connect(_on_play_offline)
	# BACK — collapse the tray, restore the OFFLINE / LOCAL / ONLINE choice.
	var back := _button(tray, "‹  BACK", Vector2(90, 1640), Vector2(320, 84), 32)
	back.pressed.connect(func() -> void: _click(); _close_difficulty())
	tray.visible = false
	return tray


## OFFLINE pressed → reveal the difficulty tray (default the highlight to the last-chosen
## tier) and hide the mode buttons so the tray owns the band.
func _open_difficulty() -> void:
	if not is_instance_valid(_difficulty_tray):
		return
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null and "ai_difficulty" in gs:
		_selected_difficulty = clampi(int(gs.ai_difficulty), 0, 2)
	for b in _quick_modes:
		if is_instance_valid(b):
			b.visible = false
	if is_instance_valid(_quick_back):
		_quick_back.visible = false
	_difficulty_tray.visible = true
	_refresh_difficulty_selection()


## Collapse the tray, restore the OFFLINE / LOCAL / ONLINE choice. Also called on every
## QuickMatch (re)entry so a stale-open tray never lingers.
func _close_difficulty() -> void:
	if is_instance_valid(_difficulty_tray):
		_difficulty_tray.visible = false
	for b in _quick_modes:
		if is_instance_valid(b):
			b.visible = true
	if is_instance_valid(_quick_back):
		_quick_back.visible = true


## A difficulty stop was clicked — move the highlighted "handle" (PLAY launches it).
func _select_difficulty(tier: int) -> void:
	_selected_difficulty = clampi(tier, 0, 2)
	_refresh_difficulty_selection()


## Light the selected stop (the slider "handle") and dim the others.
func _refresh_difficulty_selection() -> void:
	for i in _diff_segments.size():
		var seg: Button = _diff_segments[i]
		if not is_instance_valid(seg):
			continue
		seg.modulate = Color(1.0, 0.96, 0.72) if i == _selected_difficulty \
				else Color(0.66, 0.70, 0.82, 0.7)


## PLAY pressed — persist the chosen tier (the offline AIBrainComponent reads it at
## _ready) and launch the offline match.
func _on_play_offline() -> void:
	_click()
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null and gs.has_method(&"set_ai_difficulty"):
		gs.set_ai_difficulty(_selected_difficulty)
	if _nm != null:
		_nm.start_offline()


func _panel_local_choice() -> Control:
	var p := _panel()
	_title(p, "LOCAL (LAN)", 1120)
	var host := _button(p, "HOST A MATCH", Vector2(140, 1280), Vector2(800, 130), 46)
	host.pressed.connect(func() -> void: _click(); _send("host"))
	var search := _button(p, "FIND A MATCH", Vector2(140, 1440), Vector2(800, 130), 46)
	search.pressed.connect(func() -> void: _click(); _send("search"))
	_back(p, func() -> void: _send("back"))
	return p


func _panel_hosting() -> Control:
	var p := _panel()
	_title(p, "HOSTING…", 1180)
	var l := _label(p, "Broadcasting on the local network.\nWaiting for a player to join…", Vector2(120, 1300), 34)
	l.size = Vector2(840, 200)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_back(p, func() -> void: _click(); _send("back"), "CANCEL")
	return p


func _panel_searching() -> Control:
	var p := _panel()
	_title(p, "LAN LOBBIES", 1140)
	_lan_list = VBoxContainer.new()
	_lan_list.position = Vector2(140, 1240)
	_lan_list.size = Vector2(800, 420)
	_lan_list.add_theme_constant_override(&"separation", 14)
	p.add_child(_lan_list)
	_label(p, "Searching…", Vector2(140, 1200), 26)
	_back(p, func() -> void: _click(); _send("back"))
	return p


func _panel_connecting() -> Control:
	var p := _panel()
	_title(p, "CONNECT", 1040)
	_label(p, "Server address — paste your host's IP\n(leave as-is for the local dev server):", Vector2(120, 1130), 30).size = Vector2(840, 96)
	_server_input = LineEdit.new()
	_server_input.position = Vector2(120, 1240)
	_server_input.size = Vector2(840, 80)
	_server_input.placeholder_text = "1.2.3.4   or   https://my.host[:7350]"
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null and gs.has_method(&"nakama_address_text"):
		_server_input.text = gs.nakama_address_text()
	p.add_child(_server_input)
	var connect_btn := _button(p, "CONNECT", Vector2(120, 1360), Vector2(840, 120), 46)
	connect_btn.pressed.connect(_on_connect_pressed)
	_back(p, func() -> void: _click(); _send("back"))
	return p


func _panel_online_home() -> Control:
	var p := _panel()
	_title(p, "ONLINE", 1060)
	_my_id_label = _label(p, "id: …", Vector2(120, 1130), 24)
	_my_id_label.size = Vector2(840, 40)
	# Add-friend row.
	_friend_input = LineEdit.new()
	_friend_input.position = Vector2(120, 1185)
	_friend_input.size = Vector2(580, 70)
	_friend_input.placeholder_text = "friend user id"
	p.add_child(_friend_input)
	var add := _button(p, "ADD", Vector2(720, 1185), Vector2(220, 70), 32)
	add.pressed.connect(func() -> void: _click(); _nm.nakama_add_friend(_friend_input.text))
	# Friends list (rebuilt on nakama_friends).
	_friend_list = VBoxContainer.new()
	_friend_list.position = Vector2(120, 1280)
	_friend_list.size = Vector2(840, 340)
	_friend_list.add_theme_constant_override(&"separation", 12)
	p.add_child(_friend_list)
	# Inbound invite prompt area.
	_invite_box = VBoxContainer.new()
	_invite_box.position = Vector2(120, 1640)
	_invite_box.size = Vector2(840, 120)
	p.add_child(_invite_box)
	_back(p, func() -> void: _click(); _send("back"))
	return p


func _panel_inviting() -> Control:
	var p := _panel()
	_title(p, "INVITE SENT", 1180)
	_label(p, "Waiting for your friend to accept…", Vector2(120, 1300), 34).size = Vector2(840, 120)
	_back(p, func() -> void: _click(); _send("back"))
	return p


func _panel_handshake() -> Control:
	var p := _panel()
	_title(p, "OPPONENT FOUND", 1240)
	_label(p, "Loading the arena…", Vector2(120, 1360), 36).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return p


# =====================================================================
# STATE entry/exit  (panel visibility + the network action for that state)
# =====================================================================
func _on_state_entered(st: Node) -> void:
	if _panels.has(st):
		_panels[st].visible = true
	match String(st.name):
		"QuickMatch":
			# Landing on the hub (incl. after Back/failure) tears down any
			# half-open lobby/connection so a fresh choice starts clean.
			if _nm != null: _nm.cancel_lobby()
			# Always show the mode list — collapse a difficulty tray left open on a prior visit.
			_close_difficulty()
		"Hosting":
			if _nm != null: _nm.lan_host("Spell Bop host")
		"Searching":
			if _nm != null: _nm.lan_search()
		# Connecting no longer auto-connects: the panel shows the server-address field
		# and the CONNECT button (_on_connect_pressed) saves it + calls nakama_connect.


func _on_state_exited(st: Node) -> void:
	if _panels.has(st):
		_panels[st].visible = false


## CONNECT pressed on the Connecting panel: persist the pasted server address, then
## reach it. "Paste my host's IP" -> set GameSettings -> NetworkManager.nakama_connect.
func _on_connect_pressed() -> void:
	_click()
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null and is_instance_valid(_server_input):
		var parsed: Dictionary = gs.parse_nakama_address(_server_input.text)
		gs.set_nakama_server(parsed["host"], parsed["port"], parsed["scheme"])
	if _nm != null:
		_nm.nakama_connect()


# =====================================================================
# NetworkManager signals -> chart events / list refreshes
# =====================================================================
func _wire_network_signals() -> void:
	if _nm == null:
		return
	_nm.status.connect(func(m: String) -> void: if is_instance_valid(_status): _status.text = m)
	_nm.peer_joined.connect(func(_id: int) -> void: _send("peer_joined"))
	_nm.connection_failed.connect(func(reason: String) -> void:
		if is_instance_valid(_status): _status.text = "✗ " + reason
		_send("failed"))
	_nm.nakama_connected.connect(func(uid: String) -> void:
		if is_instance_valid(_my_id_label): _my_id_label.text = "id: " + uid
		_send("online_ready"))
	_nm.nakama_friends.connect(_refresh_friends)
	_nm.lan_lobbies.connect(_refresh_lan_list)
	_nm.nakama_invite.connect(_on_invite)


func _refresh_lan_list(lobbies: Array) -> void:
	if not is_instance_valid(_lan_list):
		return
	for c in _lan_list.get_children():
		c.queue_free()
	if lobbies.is_empty():
		var none := Label.new()
		none.text = "(no lobbies found yet…)"
		none.add_theme_font_size_override(&"font_size", 28)
		_lan_list.add_child(none)
		return
	for lobby in lobbies:
		var b := Button.new()
		b.text = "%s   (%s)" % [lobby.get("name", "host"), lobby.get("ip", "?")]
		b.custom_minimum_size = Vector2(800, 84)
		b.add_theme_font_size_override(&"font_size", 32)
		b.pressed.connect(func() -> void: _click(); _nm.lan_join(lobby))
		_lan_list.add_child(b)


func _refresh_friends(friends: Array) -> void:
	if not is_instance_valid(_friend_list):
		return
	for c in _friend_list.get_children():
		c.queue_free()
	if friends.is_empty():
		var none := Label.new()
		none.text = "(no friends yet — add by id above)"
		none.add_theme_font_size_override(&"font_size", 26)
		_friend_list.add_child(none)
		return
	for fr in friends:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(840, 80)
		var name_lbl := Label.new()
		name_lbl.text = "%s  %s" % [fr.get("username", "?"), _friend_state_tag(int(fr.get("state", 0)))]
		name_lbl.custom_minimum_size = Vector2(520, 80)
		name_lbl.add_theme_font_size_override(&"font_size", 30)
		row.add_child(name_lbl)
		var state := int(fr.get("state", 0))
		if state == 2:  # incoming request
			var acc := Button.new()
			acc.text = "ACCEPT"
			acc.add_theme_font_size_override(&"font_size", 28)
			acc.pressed.connect(func() -> void: _click(); _nm.nakama_accept_friend(fr.get("id", "")))
			row.add_child(acc)
		elif state == 0:  # mutual -> can invite to a match
			var inv := Button.new()
			inv.text = "INVITE"
			inv.add_theme_font_size_override(&"font_size", 28)
			inv.pressed.connect(func() -> void: _click(); _nm.nakama_host_and_invite(fr.get("id", "")); _send("inviting"))
			row.add_child(inv)
		_friend_list.add_child(row)


func _on_invite(from_name: String, match_id: String) -> void:
	if not is_instance_valid(_invite_box):
		return
	for c in _invite_box.get_children():
		c.queue_free()
	var b := Button.new()
	b.text = "▶ %s invited you — JOIN" % from_name
	b.custom_minimum_size = Vector2(840, 100)
	b.add_theme_font_size_override(&"font_size", 32)
	b.pressed.connect(func() -> void: _click(); _nm.nakama_accept_invite(match_id))
	_invite_box.add_child(b)


func _friend_state_tag(state: int) -> String:
	match state:
		0: return "•"
		1: return "(sent)"
		2: return "(wants to add you)"
		_: return ""


# =====================================================================
# tiny UI builders (match home_screen.gd's code-built style)
# =====================================================================
func _panel() -> Control:
	var p := Control.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _title(p: Control, text: String, y: float) -> Label:
	var l := Label.new()
	l.text = text
	l.position = Vector2(60, y)
	l.size = Vector2(960, 80)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override(&"font_size", 64)
	l.theme_type_variation = &"TitleLabel"
	p.add_child(l)
	return l


func _label(p: Control, text: String, pos: Vector2, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override(&"font_size", font_size)
	p.add_child(l)
	return l


func _button(p: Control, text: String, pos: Vector2, btn_size: Vector2, font_size: int) -> Y2KButton:
	var b := Y2KButton.new()
	b.text = text
	b.position = pos
	b.size = btn_size
	b.add_theme_font_size_override(&"font_size", font_size)
	p.add_child(b)
	return b


## A frosted-acrylic plate — the synthwave diorama blurs through it (frosted_panel.gdshader).
func _frost(pos: Vector2, sz: Vector2) -> ColorRect:
	var r := ColorRect.new()
	r.position = pos
	r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = FROST_SHADER
	m.set_shader_parameter(&"rect_size", sz)   # drives the rounded-corner SDF mask
	r.material = m
	return r


func _back(p: Control, on_press: Callable, text: String = "BACK") -> Button:
	var b := _button(p, text, Vector2(90, 1700), Vector2(420, 96), 36)
	b.pressed.connect(on_press)
	return b


func _click() -> void:
	var sfx := get_node_or_null(^"/root/SoundFX")
	if sfx != null and sfx.has_method(&"play"):
		sfx.play(&"ui_click")
