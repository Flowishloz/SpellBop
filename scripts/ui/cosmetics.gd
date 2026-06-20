## cosmetics.gd — The 3D COSMETICS / skin-selection screen.
##
## A moody 80s/Y2K evening DIORAMA (a Node3D world rendered straight to the window) behind a
## CanvasLayer UI overlay — the proven home_screen.gd pattern (NOT a SubViewport: the diorama is
## full-screen behind a full-screen UI, so the CanvasLayer-over-Node3D approach is simplest and
## matches the rest of the project). Everything 3D is built in code per the graveyard rule (no
## hand-authored rotated .tscn transforms — every angle comes from this script).
##
## VISUAL-PLACEHOLDERS-ONLY pass (Creative Director choice): the skin CAROUSEL live-previews skins on
## the podium via WizardAnimator.set_skin (the in-scene shader proof). The LOCKER grid + SHOP (Purchase
## button, price tags, Coins/Gems currency display) are LAYOUT placeholders — nothing is persisted,
## deducted, or equipped onto the match wizard yet (those are the flagged follow-ups: GameSettings
## persistence + equipped->match wiring + Nakama inventory RPCs). PRESENTATION ONLY — never the sim.
extends Node3D

const HOME_SCENE := "res://scenes/home_screen.tscn"
const WIZARD_TRIM := preload("res://scenes/cosmetics_wizard.tscn")
const UI_THEME := preload("res://ui/main_theme.tres")
const FROST_SHADER := preload("res://ui/frosted_panel.gdshader")

# Placeholder economy (DISPLAY ONLY this pass — not spent, not saved).
var _coins: int = 1250
var _gems: int = 8

var _podium_pivot: Node3D            # hovering pivot the wizard trim rides (animator owns the rig Y)
var _podium_base_y: float = 0.55
var _animator: Node = null           # the trim's WizardAnimator (set_skin / live preview target)
var _skins: Array = []               # SkinPalette list, catalog order
var _index: int = 0                  # current carousel index
var _equipped_id: StringName = &""   # session-only equipped marker (visual placeholder)

# UI refs
var _skin_name: Label
var _skin_status: Label
var _coins_label: Label
var _gems_label: Label
var _purchase_btn: Button
var _equip_btn: Button
var _opp_toggle: Button               # DEBUG toggle: "Equip skin for opponent" (offline-only effect)
var _equip_for_opponent: bool = false # when true, EQUIP targets the AI opponent (offline) not the player
var _hover_toggle: Button             # DEBUG toggle: "Hover mode" (the optional hover/flight animation)
var _locker: Panel
var _locker_open: bool = false


func _ready() -> void:
	_skins = SkinCatalog.skins()
	_build_environment()
	_build_camera()
	_build_ground_and_streetlight()
	_build_vending_machine()
	_build_podium_and_wizard()
	_build_fireflies()
	_build_ui()
	# Open the carousel on the player's EQUIPPED skin (persisted in GameSettings) so the wardrobe shows
	# what they're currently wearing on the title screen.
	_equipped_id = _read_equipped_skin()
	_index = maxi(0, SkinCatalog.index_of(_equipped_id))
	_apply_index(false)


func _process(_delta: float) -> void:
	# Gentle podium hover (the billboard ignores Y-rotation, so we BOB rather than spin). Bobbing the
	# PIVOT is safe: the WizardAnimator only writes the WizardRig (a child), never this pivot.
	if _podium_pivot != null:
		var t: float = Time.get_ticks_msec() / 1000.0
		_podium_pivot.position.y = _podium_base_y + sin(t * 1.1) * 0.05


# =====================================================================
# 3D DIORAMA
# =====================================================================
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.008, 0.008, 0.022)   # very dark night sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.10, 0.12, 0.22)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.05               # little soft bloom: only the lamp (above the HDR threshold) glows
	env.glow_hdr_threshold = 1.05       # ring / vending / wizard sit below this now — the lamp is the glow
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	# Fog tinted to the SKY colour (+ aerial perspective) so the ground fades INTO the sky — the
	# horizon line disappears instead of cutting a hard edge across the frame.
	env.fog_enabled = true
	env.fog_light_color = Color(0.008, 0.008, 0.022)
	env.fog_aerial_perspective = 1.0
	env.fog_density = 0.032
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_camera() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 2.0, 5.4)   # pulled back + raised so the side props fit the portrait frame
	cam.fov = 50.0
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.5, 0.0), Vector3.UP)
	cam.current = true


func _build_ground_and_streetlight() -> void:
	# Dark ground with a faint sheen to catch the neon + the streetlight pool.
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(44, 44)   # large, so its far edge sits deep in the fog (no visible rim)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.024, 0.024, 0.04)   # near the sky colour so the horizon blends away
	floor_mat.metallic = 0.3
	floor_mat.roughness = 0.5
	floor_mesh.material = floor_mat
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	add_child(floor_node)

	# --- STREET LIGHT: pole + arm (script rotation) + lamp head + the dramatic spotlight onto the
	# podium. The pole sits back-left; its arm reaches over the podium so the cone falls on centre.
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.06, 0.06, 0.08)
	metal.metallic = 0.7
	metal.roughness = 0.4
	var pole_base := Vector3(-1.7, 0.0, -1.6)  # whole lamp/pole shifted ~20% left so the lamp isn't centered

	var pole := CylinderMesh.new()
	pole.top_radius = 0.07
	pole.bottom_radius = 0.09
	pole.height = 4.6
	pole.material = metal
	var pole_node := MeshInstance3D.new()
	pole_node.mesh = pole
	pole_node.position = pole_base + Vector3(0, 2.3, 0)
	add_child(pole_node)

	var arm := CylinderMesh.new()
	arm.top_radius = 0.05
	arm.bottom_radius = 0.06
	arm.height = 1.2
	arm.material = metal
	var arm_node := MeshInstance3D.new()
	arm_node.mesh = arm
	arm_node.rotation = Vector3(0, 0, deg_to_rad(90.0))  # lay it horizontal, reaching along +X
	arm_node.position = pole_base + Vector3(0.5, 4.5, 0)
	add_child(arm_node)

	var head_pos := pole_base + Vector3(1.0, 4.4, 0.0)  # lamp + light UNCHANGED at x -> 0.0 (above podium)
	var head := BoxMesh.new()
	head.size = Vector3(0.52, 0.22, 0.36)
	head.material = metal
	var head_node := MeshInstance3D.new()
	head_node.mesh = head
	head_node.position = head_pos
	add_child(head_node)
	# Warm emissive lens on the underside of the lamp head.
	var lens := BoxMesh.new()
	lens.size = Vector3(0.42, 0.06, 0.28)
	lens.material = _emissive(Color(1.0, 0.82, 0.5), 3.2)   # the lamp is the one thing that still glows
	var lens_node := MeshInstance3D.new()
	lens_node.mesh = lens
	lens_node.position = head_pos + Vector3(0, -0.13, 0)
	add_child(lens_node)

	var spot := SpotLight3D.new()
	spot.position = head_pos + Vector3(0, -0.16, 0)
	spot.light_color = Color(1.0, 0.80, 0.5)
	spot.light_energy = 7.5
	spot.spot_range = 9.5
	spot.spot_angle = 36.0
	spot.spot_angle_attenuation = 1.1
	spot.shadow_enabled = true
	add_child(spot)
	spot.look_at(Vector3(0, 0.55, 0), Vector3(0, 0, -1))

	# A small warm HALO at the lamp head so the (re-centred) pole + the lamp-swarming fireflies read in
	# the darker scene. This is the lamp's own soft glow — the dramatic podium SPOTLIGHT above is unchanged.
	var lamp_glow := OmniLight3D.new()
	lamp_glow.position = head_pos
	lamp_glow.light_color = Color(1.0, 0.82, 0.5)
	lamp_glow.light_energy = 3.0
	lamp_glow.omni_range = 2.7
	add_child(lamp_glow)


func _build_vending_machine() -> void:
	# A low-poly vending machine in the background with a softly glowing window. Built under a single
	# rotated root (graveyard rule: one script rotation, children stay axis-aligned in local space).
	var machine := Node3D.new()
	machine.position = Vector3(1.7, 0.0, -4.0)           # right-back, inside the portrait frame
	machine.rotation = Vector3(0, deg_to_rad(-22.0), 0)  # angled toward the podium
	add_child(machine)

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.09, 0.07, 0.13)
	body_mat.metallic = 0.5
	body_mat.roughness = 0.4
	var body := BoxMesh.new()
	body.size = Vector3(1.3, 2.1, 0.75)
	body.material = body_mat
	var body_node := MeshInstance3D.new()
	body_node.mesh = body
	body_node.position = Vector3(0, 1.05, 0)
	machine.add_child(body_node)

	# Softly glowing front window (cyan).
	var window := BoxMesh.new()
	window.size = Vector3(0.96, 1.26, 0.05)
	window.material = _emissive(Color(0.32, 0.85, 1.0), 0.8)   # dim — only the lamp glows now
	var win_node := MeshInstance3D.new()
	win_node.mesh = window
	win_node.position = Vector3(0, 1.28, 0.39)
	machine.add_child(win_node)

	# THREE ROWS of items behind the glass — DESATURATED, washed-out silhouettes (not vivid product art).
	var item_cols := [
		Color(0.40, 0.33, 0.34), Color(0.43, 0.41, 0.33), Color(0.33, 0.38, 0.44),
		Color(0.36, 0.41, 0.36), Color(0.42, 0.36, 0.41), Color(0.34, 0.37, 0.44),
		Color(0.44, 0.39, 0.33), Color(0.43, 0.43, 0.45), Color(0.36, 0.42, 0.41),
	]
	var rows := [0.92, 1.28, 1.64]   # three shelves up the window
	var cols := [-0.3, 0.0, 0.3]
	var shelf_mat := StandardMaterial3D.new()
	shelf_mat.albedo_color = Color(0.04, 0.06, 0.09)
	for r in 3:
		for c in 3:
			var item := BoxMesh.new()
			item.size = Vector3(0.22, 0.26, 0.02)
			var im := StandardMaterial3D.new()
			im.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			im.albedo_color = item_cols[r * 3 + c]
			item.material = im
			var item_node := MeshInstance3D.new()
			item_node.mesh = item
			item_node.position = Vector3(cols[c], rows[r], 0.41)
			machine.add_child(item_node)
		var shelf := BoxMesh.new()
		shelf.size = Vector3(0.92, 0.03, 0.05)
		shelf.material = shelf_mat
		var shelf_node := MeshInstance3D.new()
		shelf_node.mesh = shelf
		shelf_node.position = Vector3(0.0, rows[r] - 0.17, 0.41)
		machine.add_child(shelf_node)

	# Soft glow spill from the window.
	var glow := OmniLight3D.new()
	glow.position = Vector3(0, 1.3, 0.8)
	glow.light_color = Color(0.4, 0.85, 1.0)
	glow.light_energy = 1.3
	glow.omni_range = 4.0
	machine.add_child(glow)


func _build_podium_and_wizard() -> void:
	# Cylindrical display dais.
	var dais := CylinderMesh.new()
	dais.top_radius = 0.92
	dais.bottom_radius = 1.05
	dais.height = 0.55
	var dais_mat := StandardMaterial3D.new()
	dais_mat.albedo_color = Color(0.10, 0.10, 0.14)
	dais_mat.metallic = 0.4
	dais_mat.roughness = 0.35
	dais.material = dais_mat
	var dais_node := MeshInstance3D.new()
	dais_node.mesh = dais
	dais_node.position = Vector3(0, 0.275, 0)
	add_child(dais_node)

	# Neon trim ring around the top edge (cyan, blooms). TorusMesh lies flat in XZ by default.
	var ring := TorusMesh.new()
	ring.inner_radius = 0.90
	ring.outer_radius = 1.0
	ring.material = _emissive(Color(0.35, 0.9, 1.0), 0.5)   # dim — only the lamp glows now
	var ring_node := MeshInstance3D.new()
	ring_node.mesh = ring
	ring_node.position = Vector3(0, 0.55, 0)
	add_child(ring_node)

	# The wizard trim hovers on the podium (its own +1.05 sprite offset plants the feet on top).
	_podium_pivot = Node3D.new()
	_podium_pivot.position = Vector3(0, _podium_base_y, 0)
	add_child(_podium_pivot)
	var trim := WIZARD_TRIM.instantiate()
	_podium_pivot.add_child(trim)
	_animator = trim.get_node_or_null("WizardAnimator")


func _build_fireflies() -> void:
	# Two slow drifting glow layers around the podium (the home_screen firefly pattern).
	for fdata in [
		[Color(0.95, 0.9, 0.45, 0.9), 9, 0.045],
		[Color(0.5, 0.95, 0.6, 0.6), 6, 0.06],
	]:
		var quad := QuadMesh.new()
		quad.size = Vector2(fdata[2], fdata[2])
		var glow := StandardMaterial3D.new()
		glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.albedo_color = fdata[0]
		glow.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		quad.material = glow
		var flies := CPUParticles3D.new()
		flies.mesh = quad
		flies.amount = fdata[1]
		flies.lifetime = 8.0
		flies.preprocess = 8.0
		flies.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		flies.emission_box_extents = Vector3(0.9, 0.8, 0.8)
		flies.position = Vector3(-0.7, 4.1, -1.6)   # swarming around the (left-shifted) street-lamp head
		flies.direction = Vector3(0, 1, 0)
		flies.spread = 180.0
		flies.gravity = Vector3.ZERO
		flies.initial_velocity_min = 0.04
		flies.initial_velocity_max = 0.18
		flies.color = fdata[0]
		add_child(flies)


## A shaded emissive material that blooms (emission energy > 1 clears the glow HDR threshold).
func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color.darkened(0.35)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.roughness = 0.4
	return m


# =====================================================================
# UI OVERLAY (CanvasLayer over the 3D — portrait 1080x1920)
# =====================================================================
func _build_ui() -> void:
	var ui := CanvasLayer.new()
	ui.layer = 1
	add_child(ui)

	# Themed root: the universal Y2K theme (res://ui/main_theme.tres) cascades to EVERY Control below.
	# (A CanvasLayer is not a Control, so the theme rides a full-rect root instead.) IGNORE filter so
	# the root itself never eats clicks — its child buttons are still hit-tested independently.
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UI_THEME
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)

	# ONE slim frosted plate frames just the skin name/status (light + minimal — no big containers;
	# the back / currency / carousel all float as light rounded buttons over the diorama).
	root.add_child(_frost(Vector2(190, 250), Vector2(700, 162)))     # skin name / status

	# BACK at the bottom-left (consistent with the deck builder + other menus); currency stays top-right.
	var back := _btn("‹  BACK", Vector2(40, 1690), Vector2(200, 92), 34)
	back.pressed.connect(func() -> void: _click(); get_tree().change_scene_to_file(HOME_SCENE))
	root.add_child(back)
	_build_currency_display(root)

	# Title (theme TitleLabel variation = heavy tracked header font, stark white).
	var title := _lbl("COSMETICS", Vector2(60, 150), Vector2(960, 90), 64, HORIZONTAL_ALIGNMENT_CENTER)
	title.theme_type_variation = &"TitleLabel"
	root.add_child(title)

	# Skin name + status — high, just under the title (keeps the wizard hero-shot clear of text).
	_skin_name = _lbl("", Vector2(140, 262), Vector2(800, 80), 56, HORIZONTAL_ALIGNMENT_CENTER)
	_skin_name.theme_type_variation = &"HeaderLabel"
	root.add_child(_skin_name)
	_skin_status = _lbl("", Vector2(140, 352), Vector2(800, 54), 36, HORIZONTAL_ALIGNMENT_CENTER)
	root.add_child(_skin_status)

	# Carousel arrows (smaller, icon-only) flank the PURCHASE/EQUIP action; LOCKER sits below. All
	# float as light rounded frosted buttons — no heavy container plate (arrows suppress the ► cursor
	# but keep the snap-flash + press-scanline).
	var left := _btn("", Vector2(60, 1474), Vector2(132, 132), 10)
	left.show_cursor = false
	var la := ArrowIcon.new()
	la.dir = -1
	la.size = Vector2(132, 132)
	la.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(la)
	left.pressed.connect(func() -> void: _cycle(-1))
	root.add_child(left)

	var right := _btn("", Vector2(888, 1474), Vector2(132, 132), 10)
	right.show_cursor = false
	var ra := ArrowIcon.new()
	ra.dir = 1
	ra.size = Vector2(132, 132)
	ra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(ra)
	right.pressed.connect(func() -> void: _cycle(1))
	root.add_child(right)

	# Same slot: PURCHASE (locked) OR EQUIP (owned) — toggled in _refresh_skin_ui — between the arrows.
	_purchase_btn = _btn("PURCHASE", Vector2(232, 1488), Vector2(616, 104), 36)
	_purchase_btn.pressed.connect(_on_purchase)
	root.add_child(_purchase_btn)
	_equip_btn = _btn("EQUIP", Vector2(330, 1488), Vector2(420, 104), 40)
	_equip_btn.pressed.connect(_on_equip)
	root.add_child(_equip_btn)

	var locker_btn := _btn("LOCKER", Vector2(360, 1648), Vector2(360, 96), 40)
	locker_btn.pressed.connect(func() -> void: _toggle_locker())
	root.add_child(locker_btn)

	# DEBUG (bottom-left): a small toggle that retargets the EQUIP button at the AI OPPONENT instead of
	# the player. The opponent skin only takes effect in OFFLINE matches (ignored online — there the
	# opponent is a real peer). toggle_mode shows the active state via the theme's pressed stylebox.
	_opp_toggle = _btn("Equip skin for opponent", Vector2(40, 1798), Vector2(404, 76), 23)
	_opp_toggle.show_cursor = false
	_opp_toggle.toggle_mode = true
	_opp_toggle.toggled.connect(_on_opp_toggle)
	root.add_child(_opp_toggle)

	# DEBUG (bottom-right): toggle the OPTIONAL hover/flight animation (GameSettings.hover_mode) so we can
	# test it live — the podium wizard rises + floats immediately; the full liftoff + bank shows in a
	# match. PRESENTATION ONLY. Reflects (and persists) the saved state. Mirrors the opponent toggle left.
	_hover_toggle = _btn("Hover mode", Vector2(636, 1798), Vector2(404, 76), 23)
	_hover_toggle.show_cursor = false
	_hover_toggle.toggle_mode = true
	_hover_toggle.button_pressed = _read_hover_mode()   # set BEFORE connecting so it doesn't re-fire
	_hover_toggle.modulate = Color(0.55, 0.85, 1.0) if _hover_toggle.button_pressed else Color(1.0, 1.0, 1.0)
	_hover_toggle.toggled.connect(_on_hover_toggle)
	root.add_child(_hover_toggle)

	# The slide-in Locker (built last so it overlays everything; starts offscreen).
	_build_locker(root)


func _build_currency_display(parent: Control) -> void:
	# Gems (the Chaos-Emerald currency) then Coins, top-right. Icons are custom-drawn; the counts keep
	# their semantic colours (emerald-green gems / gold coins) over the icy theme chrome.
	var gem := GemIcon.new()
	gem.position = Vector2(686, 46)
	gem.size = Vector2(56, 56)
	gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(gem)
	_gems_label = _lbl(_comma(_gems), Vector2(748, 48), Vector2(110, 52), 36, HORIZONTAL_ALIGNMENT_LEFT)
	_gems_label.modulate = Color(0.5, 1.0, 0.7)
	parent.add_child(_gems_label)

	var coin := CoinIcon.new()
	coin.position = Vector2(866, 46)
	coin.size = Vector2(56, 56)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(coin)
	_coins_label = _lbl(_comma(_coins), Vector2(928, 48), Vector2(130, 52), 36, HORIZONTAL_ALIGNMENT_LEFT)
	_coins_label.modulate = Color(1.0, 0.88, 0.45)
	parent.add_child(_coins_label)


func _build_locker(parent: Control) -> void:
	# A themed Panel (frosted stylebox = the 1px silver edge) with a real frosted-blur backdrop inset
	# inside it, so the diorama blurs through the open locker (Rocket-League-garage style).
	_locker = Panel.new()
	_locker.position = Vector2(0, 1920)        # offscreen (bottom)
	_locker.size = Vector2(1080, 1320)
	_locker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := _frost(Vector2(3, 3), Vector2(1074, 1314))   # inset so the panel's silver border peeks
	var bm := bg.material as ShaderMaterial
	bm.set_shader_parameter(&"panel_alpha", 0.97)          # near-opaque over the busy diorama
	bm.set_shader_parameter(&"blur_radius", 3.4)
	_locker.add_child(bg)
	var lk_title := _lbl("LOCKER", Vector2(60, 40), Vector2(700, 80), 56, HORIZONTAL_ALIGNMENT_LEFT)
	lk_title.theme_type_variation = &"HeaderLabel"
	_locker.add_child(lk_title)
	var close := _btn("✕", Vector2(920, 36), Vector2(110, 90), 44)
	close.show_cursor = false
	close.pressed.connect(func() -> void: _toggle_locker())
	_locker.add_child(close)
	var note := _lbl("All skins (owned + shop). Tap one to preview it on the podium.",
		Vector2(60, 118), Vector2(960, 40), 26, HORIZONTAL_ALIGNMENT_LEFT)
	note.theme_type_variation = &"MutedLabel"
	_locker.add_child(note)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.position = Vector2(60, 180)
	grid.add_theme_constant_override(&"h_separation", 40)
	grid.add_theme_constant_override(&"v_separation", 40)
	_locker.add_child(grid)
	for s in _skins:
		grid.add_child(_make_locker_tile(s, SkinCatalog.entry_for(s.id)))
	parent.add_child(_locker)


func _make_locker_tile(skin: SkinPalette, entry: Dictionary) -> Control:
	var tile := Button.new()
	tile.custom_minimum_size = Vector2(460, 360)
	tile.size = Vector2(460, 360)
	tile.pressed.connect(func() -> void: _select_skin(skin.id))

	var chip := PaletteChip.new()
	chip.colors = skin.colors
	chip.position = Vector2(20, 20)
	chip.size = Vector2(420, 200)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(chip)

	var nm := _lbl(skin.display_name, Vector2(20, 230), Vector2(420, 50), 32, HORIZONTAL_ALIGNMENT_CENTER)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(nm)

	var owned: bool = SkinCatalog.is_owned(skin.id)
	var status_text := "OWNED"
	var status_col := Color(0.5, 1.0, 0.6)
	if not owned:
		var price := int(entry.get("price", 0))
		var cur: StringName = entry.get("currency", &"coins")
		status_text = "LOCKED  ·  %s %s" % [_comma(price), "GEMS" if cur == &"gems" else "COINS"]
		status_col = Color(0.55, 1.0, 0.7) if cur == &"gems" else Color(1.0, 0.85, 0.45)
	elif not bool(entry.get("owned", true)):
		status_text = "OWNED  ·  DEV"   # a paywall skin, equippable only because of the DEV master-unlock
		status_col = Color(0.62, 0.9, 1.0)
	var st := _lbl(status_text, Vector2(20, 290), Vector2(420, 46), 28, HORIZONTAL_ALIGNMENT_CENTER)
	st.modulate = status_col
	st.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(st)
	return tile


# =====================================================================
# CAROUSEL / SELECTION (live preview only — visual placeholder)
# =====================================================================
func _cycle(step: int) -> void:
	_index += step
	_apply_index(true)


func _apply_index(play_click: bool) -> void:
	if _skins.is_empty():
		return
	_index = ((_index % _skins.size()) + _skins.size()) % _skins.size()
	var skin: SkinPalette = _skins[_index]
	if _animator != null and _animator.has_method(&"set_skin"):
		_animator.set_skin(skin)   # LIVE shader preview on the podium
	_refresh_skin_ui()
	if play_click:
		_click()


func _select_skin(id: StringName) -> void:
	var idx := SkinCatalog.index_of(id)
	if idx >= 0:
		_index = idx
		_apply_index(false)
	if _locker_open:
		_toggle_locker()


func _refresh_skin_ui() -> void:
	if _skins.is_empty():
		return
	var skin: SkinPalette = _skins[_index]
	var entry := SkinCatalog.entry_for(skin.id)
	_skin_name.text = String(skin.display_name).to_upper()
	# Ownership goes through SkinCatalog.is_owned() so the DEV_UNLOCK_ALL master switch is honoured —
	# in dev EVERY skin is equippable. Flip that flag off and the price-gated PURCHASE branch below
	# (the untouched paywall framework) takes over exactly as before.
	var owned: bool = SkinCatalog.is_owned(skin.id)
	if owned:
		var is_equipped := skin.id == _equipped_id
		var dev_unlock: bool = not bool(entry.get("owned", true))   # equippable ONLY via the dev switch
		if is_equipped:
			_skin_status.text = "EQUIPPED"
		else:
			_skin_status.text = "OWNED  ·  DEV" if dev_unlock else "OWNED"
		_skin_status.modulate = Color(0.5, 1.0, 0.6)
		_purchase_btn.visible = false
		_equip_btn.visible = true
		if _equip_for_opponent:
			# DEBUG opponent mode: EQUIP always available (re-targets the AI opponent, offline only).
			_equip_btn.text = "EQUIP OPPONENT"
			_equip_btn.disabled = false
		else:
			_equip_btn.text = "EQUIPPED" if is_equipped else "EQUIP"
			_equip_btn.disabled = is_equipped
	else:
		var price := int(entry.get("price", 0))
		var cur: StringName = entry.get("currency", &"coins")
		var cur_name := "GEMS" if cur == &"gems" else "COINS"
		_skin_status.text = "%s %s" % [_comma(price), cur_name]
		_skin_status.modulate = Color(0.55, 1.0, 0.7) if cur == &"gems" else Color(1.0, 0.85, 0.45)
		_purchase_btn.visible = true
		_purchase_btn.text = "PURCHASE  ·  %s %s" % [_comma(price), cur_name]
		_equip_btn.visible = false


func _on_purchase() -> void:
	_click()
	# Backend purchasing does not exist yet (Creative Director: visual placeholder this pass).
	_flash_status("SHOP COMING SOON", Color(1.0, 0.7, 0.4))


func _on_equip() -> void:
	_click()
	var gs := get_node_or_null(^"/root/GameSettings")
	var id: StringName = _skins[_index].id
	if _equip_for_opponent:
		# DEBUG: set the AI opponent's skin instead — only takes effect in OFFLINE matches.
		if gs != null and gs.has_method(&"set_opponent_skin"):
			gs.set_opponent_skin(id)
		_flash_status("OPPONENT SET  ·  OFFLINE", Color(1.0, 0.66, 0.45))
		return
	_equipped_id = id
	# Persist the choice (GameSettings -> user://) so the MENU / title-screen wizard AND the local
	# player's in-MATCH wizard (MatchController._apply_equipped_skin) wear it across restarts.
	if gs != null and gs.has_method(&"set_equipped_skin"):
		gs.set_equipped_skin(_equipped_id)
	_refresh_skin_ui()
	_flash_status("EQUIPPED", Color(0.5, 1.0, 0.6))


## DEBUG toggle: flip the EQUIP button between dressing the PLAYER (off) and the AI OPPONENT (on). The
## opponent skin is only applied in OFFLINE matches (MatchController skips it in netplay).
func _on_opp_toggle(pressed: bool) -> void:
	_equip_for_opponent = pressed
	_click()
	_opp_toggle.modulate = Color(1.0, 0.66, 0.45) if pressed else Color(1.0, 1.0, 1.0)
	_refresh_skin_ui()


## DEBUG toggle: flip the OPTIONAL hover/flight animation on/off (GameSettings.hover_mode). Every
## WizardAnimator (the podium rig here + the match wizards) tracks it live via hover_mode_changed, so the
## podium wizard rises/sinks immediately. PRESENTATION ONLY.
func _on_hover_toggle(pressed: bool) -> void:
	_click()
	_hover_toggle.modulate = Color(0.55, 0.85, 1.0) if pressed else Color(1.0, 1.0, 1.0)
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null and gs.has_method(&"set_hover_mode"):
		gs.set_hover_mode(pressed)


## The persisted hover-mode debug toggle (default off) — reflected on the toggle button when it is built.
func _read_hover_mode() -> bool:
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null:
		var v: Variant = gs.get(&"hover_mode")
		if v != null:
			return bool(v)
	return false


func _flash_status(text: String, col: Color) -> void:
	if _skin_status == null:
		return
	_skin_status.text = text
	_skin_status.modulate = col
	var tw := create_tween()
	tw.tween_interval(1.4)
	tw.tween_callback(_refresh_skin_ui)


func _toggle_locker() -> void:
	_locker_open = not _locker_open
	_click()
	_locker.mouse_filter = Control.MOUSE_FILTER_STOP if _locker_open else Control.MOUSE_FILTER_IGNORE
	var target_y := 480.0 if _locker_open else 1920.0
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_locker, "position:y", target_y, 0.35)


# =====================================================================
# tiny builders + helpers (match the home_screen / menu_flow code style)
# =====================================================================
func _btn(text: String, pos: Vector2, sz: Vector2, font_size: int) -> Y2KButton:
	var b := Y2KButton.new()
	b.text = text
	b.position = pos
	b.size = sz
	b.add_theme_font_size_override(&"font_size", font_size)
	return b


## A frosted-acrylic plate — the 3D diorama blurs through it (frosted_panel.gdshader). Sized to sit
## BEHIND a UI cluster (add it to the parent before the cluster's controls so it stays underneath).
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


func _lbl(text: String, pos: Vector2, sz: Vector2, font_size: int, align: int) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.size = sz
	l.add_theme_font_size_override(&"font_size", font_size)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _comma(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


func _click() -> void:
	var sfx := get_node_or_null(^"/root/SoundFX")
	if sfx != null and sfx.has_method(&"play"):
		sfx.play(&"ui_click")


## The player's currently-equipped skin id (persisted in GameSettings; default = the identity blue).
func _read_equipped_skin() -> StringName:
	var gs := get_node_or_null(^"/root/GameSettings")
	if gs != null:
		var v: Variant = gs.get(&"equipped_skin")
		if v != null:
			return v
	return &"default_blue"


# =====================================================================
# custom-drawn icons (font/emoji-independent, like home_screen's GearIcon)
# =====================================================================
class ArrowIcon extends Control:
	var dir: int = 1   # 1 = right, -1 = left

	func _draw() -> void:
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		var s := minf(size.x, size.y) * 0.30
		var col := Color(0.92, 0.96, 1.0, 0.95)
		var pts: PackedVector2Array
		if dir > 0:
			pts = PackedVector2Array([Vector2(cx - s * 0.5, cy - s), Vector2(cx + s * 0.7, cy), Vector2(cx - s * 0.5, cy + s)])
		else:
			pts = PackedVector2Array([Vector2(cx + s * 0.5, cy - s), Vector2(cx - s * 0.7, cy), Vector2(cx + s * 0.5, cy + s)])
		draw_colored_polygon(pts, col)


class CoinIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.46
		draw_circle(c, r, Color(0.72, 0.52, 0.12))
		draw_circle(c, r * 0.84, Color(1.0, 0.82, 0.34))
		draw_arc(c, r * 0.84, 0.0, TAU, 28, Color(0.78, 0.56, 0.14), 4.0)
		draw_circle(c, r * 0.26, Color(0.82, 0.6, 0.18))


class GemIcon extends Control:
	# A faceted emerald — the Chaos-Emerald currency (Creative Director: "use the health emerald").
	func _draw() -> void:
		var w := size.x
		var h := size.y
		var cx := w * 0.5
		var top := h * 0.24
		var giro := h * 0.45
		var tip := h * 0.82
		var hw_top := w * 0.22
		var hw_mid := w * 0.40
		var t1 := Vector2(cx - hw_top, top)
		var t2 := Vector2(cx + hw_top, top)
		var g1 := Vector2(cx - hw_mid, giro)
		var g2 := Vector2(cx + hw_mid, giro)
		var gc := Vector2(cx, giro)
		var pb := Vector2(cx, tip)
		var lite := Color(0.5, 1.0, 0.66)
		var base := Color(0.18, 0.82, 0.45)
		var dark := Color(0.08, 0.5, 0.28)
		draw_colored_polygon(PackedVector2Array([t1, t2, g2, g1]), lite)   # crown table
		draw_colored_polygon(PackedVector2Array([g1, gc, pb]), base)        # pavilion left
		draw_colored_polygon(PackedVector2Array([gc, g2, pb]), dark)        # pavilion right
		draw_polyline(PackedVector2Array([t1, t2, g2, pb, g1, t1]), Color(0.03, 0.3, 0.18), 3.0)


class PaletteChip extends Control:
	# The skin's recolour signature — its palette as vertical stripes (the locker swatch identity).
	var colors: PackedColorArray

	func _draw() -> void:
		if colors.is_empty():
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.15, 0.15, 0.2))
			return
		var n := colors.size()
		var bw := size.x / float(n)
		for i in n:
			draw_rect(Rect2(float(i) * bw, 0.0, bw + 1.0, size.y), colors[i])
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.0), false, 2.0)
