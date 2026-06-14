## home_screen.gd — The SPELL BOP home screen.
##
## A small 3D diorama + UI layer, ALL built in code (graveyard rule: no
## hand-authored rotated transforms in .tscn — every angled thing here gets
## its rotation from this script):
##   - "SPELL BOP" along the top: extruded TextMesh letters, Y2K chrome,
##     floating with a per-letter wobble.
##   - The wizard mid-left; a low-poly deck of cards (half the wizard's
##     size) to its right, angled, with a few cards poking out untidily.
##   - Firefly particles drifting through the scene.
##   - Buttons: STORY MODE + ONLINE MATCH at the bottom, with DECKS /
##     INVENTORY / SHOP placeholders beneath; settings gear top-right.
extends Node3D

const MATCH_SCENE := "res://scenes/match_arena.tscn"

## Per-letter wobble tuning.
@export var wobble_height: float = 0.07
@export var wobble_speed: float = 1.6

var _letters: Array[MeshInstance3D] = []
var _letter_base_y: float = 3.1
var _deck: Node3D
# Floating card-backs behind the title (fanned, own looping drift).
var _title_cards: Array[MeshInstance3D] = []
const TITLE_CARD_BASE := Vector3(0.0, 3.45, -3.6)
const TITLE_CARD_FAN_X: Array[float] = [-0.85, 0.0, 0.85]
const TITLE_CARD_FAN_ROT: Array[float] = [-0.22, 0.0, 0.22]


## Custom-drawn gear icon (no texture assets needed).
class GearIcon extends Control:
	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var r: float = minf(size.x, size.y) * 0.32
		for i in 8:
			var a: float = TAU * float(i) / 8.0
			var dir := Vector2(cos(a), sin(a))
			draw_line(c + dir * r * 0.7, c + dir * (r * 1.45), Color(0.9, 0.9, 0.95, 0.9), 9.0)
		draw_circle(c, r, Color(0.9, 0.9, 0.95, 0.9))
		draw_circle(c, r * 0.45, Color(0.1, 0.1, 0.14, 1.0))


func _ready() -> void:
	_build_title()
	_build_title_cards()
	_build_diorama()
	_build_ui()


## Three card-backs floating BEHIND the title — 35% taller than the letters,
## a fifth of their depth, fanned like a held hand, drifting on their own
## slow loop (distinct from the letters' wobble).
func _build_title_cards() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://resources/placeholder/card_back.png")
	mat.albedo_color = Color(0.5, 0.5, 0.58)  # dimmed — backdrop, not subject
	mat.roughness = 0.65
	var card_mesh := BoxMesh.new()
	# Letters ~0.8 m tall -> cards 1.08 m; depth 20% of the 0.2 letter depth.
	card_mesh.size = Vector3(0.78, 1.08, 0.04)
	card_mesh.material = mat
	for i in 3:
		var card := MeshInstance3D.new()
		card.mesh = card_mesh
		card.position = TITLE_CARD_BASE + Vector3(TITLE_CARD_FAN_X[i], 0.0, -0.04 * float(i))
		card.rotation.z = TITLE_CARD_FAN_ROT[i]
		add_child(card)
		_title_cards.append(card)


func _process(_delta: float) -> void:
	# Per-letter float + wobble (Y2K screensaver energy), plus a lazy deck sway.
	var t: float = Time.get_ticks_msec() / 1000.0
	for i in _letters.size():
		var letter: MeshInstance3D = _letters[i]
		var phase: float = float(i) * 0.8
		letter.position.y = _letter_base_y + sin(t * wobble_speed + phase) * wobble_height
		letter.rotation.y = sin(t * 1.2 + phase * 1.3) * 0.14
		letter.rotation.z = sin(t * 0.9 + phase) * 0.05
	if _deck != null:
		_deck.rotation.y = deg_to_rad(-26.0) + sin(t * 0.5) * 0.05
		_deck.position.y = 0.55 + sin(t * 0.8) * 0.04  # gentle hover bob

	# Title cards: a lazy elliptical drift on a DIFFERENT loop than the
	# letters' wobble, with a slow fan-breath in the tilt.
	for i in _title_cards.size():
		var card: MeshInstance3D = _title_cards[i]
		var phase: float = float(i) * 2.1
		card.position.x = TITLE_CARD_BASE.x + TITLE_CARD_FAN_X[i] + cos(t * 0.45 + phase) * 0.09
		card.position.y = TITLE_CARD_BASE.y + sin(t * 0.7 + phase) * 0.12
		card.rotation.z = TITLE_CARD_FAN_ROT[i] + sin(t * 0.55 + phase) * 0.06
		card.rotation.y = sin(t * 0.4 + phase) * 0.1


# =====================================================================
# 3D content
# =====================================================================

func _build_title() -> void:
	var chrome := StandardMaterial3D.new()
	chrome.albedo_color = Color(0.75, 0.85, 1.0)
	chrome.metallic = 0.9
	chrome.roughness = 0.22
	chrome.emission_enabled = true
	chrome.emission = Color(0.25, 0.3, 0.6)
	chrome.emission_energy_multiplier = 0.5

	# Kerning pass (Creative Director): narrow glyphs ('L') advance less so
	# BOP shifts centerward and its wide letters get breathing room.
	var word: String = "SPELL BOP"
	var space_advance: float = 0.18
	var advances: Dictionary = {"L": 0.28, "I": 0.26}
	var total: float = 0.0
	for i in word.length():
		var c: String = word[i]
		total += space_advance if c == " " else float(advances.get(c, 0.38))
	var x: float = -(total - 0.38) * 0.5
	for i in word.length():
		var ch: String = word[i]
		if ch == " ":
			x += space_advance
			continue
		if ch != " ":
			var mesh := TextMesh.new()
			mesh.text = ch
			mesh.font = ThemeDB.fallback_font
			mesh.font_size = 80
			mesh.pixel_size = 0.01
			mesh.depth = 0.2
			mesh.material = chrome
			var letter := MeshInstance3D.new()
			letter.mesh = mesh
			letter.position = Vector3(x, _letter_base_y, -1.0)
			add_child(letter)
			_letters.append(letter)
		x += float(advances.get(ch, 0.38))


func _build_diorama() -> void:
	# Hero wizard (~2 m tall), pulled toward center.
	var wizard := Sprite3D.new()
	wizard.texture = load("res://resources/placeholder/wizard_blue.png")
	wizard.pixel_size = 0.008
	wizard.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	wizard.position = Vector3(-0.62, 1.05, 0.0)
	add_child(wizard)

	# Low-poly deck LYING FACE-DOWN like cards on a table (Creative Director
	# fix — it stood upright before): footprint on X/Z, thickness on Y.
	# It HOVERS beside the wizard (magic) so it doesn't sink into the
	# bottom button row.
	_deck = Node3D.new()
	_deck.position = Vector3(0.62, 0.55, 0.1)
	add_child(_deck)
	# Textured: the back carries the centered oval emblem, the edge block a
	# subtle stack-of-cards line texture (Creative Director polish).
	var card_back := StandardMaterial3D.new()
	card_back.albedo_texture = load("res://resources/placeholder/card_back.png")
	card_back.roughness = 0.6
	var card_edge := StandardMaterial3D.new()
	card_edge.albedo_texture = load("res://resources/placeholder/deck_side.png")
	card_edge.roughness = 0.85

	# White card-edge block (the stacked sides) with a purple back on top.
	var stack_mesh := BoxMesh.new()
	stack_mesh.size = Vector3(0.66, 0.3, 0.9)
	stack_mesh.material = card_edge
	var stack := MeshInstance3D.new()
	stack.mesh = stack_mesh
	stack.position = Vector3(0, 0.15, 0)
	_deck.add_child(stack)
	var top_mesh := BoxMesh.new()
	top_mesh.size = Vector3(0.64, 0.02, 0.88)
	top_mesh.material = card_back
	var top := MeshInstance3D.new()
	top.mesh = top_mesh
	top.position = Vector3(0, 0.31, 0)
	_deck.add_child(top)

	# Stray cards slid out of the pile FLAT, untidy (script-applied yaws):
	# two near the bottom poking right/left, and a THIRD near the TOP of the
	# pile, slid the OPPOSITE way and poking out least (Creative Director).
	var stray_mesh := BoxMesh.new()
	stray_mesh.size = Vector3(0.6, 0.02, 0.84)
	stray_mesh.material = card_back
	# Composition pass: bottom stray pulled 20% inward; top stray pushed 20%
	# of a card-length toward the camera (Creative Director).
	for stray_data in [
		[Vector3(0.13, 0.08, 0.11), 0.3],
		[Vector3(-0.14, 0.05, 0.1), -0.22],
		[Vector3(-0.08, 0.26, 0.13), -0.1],
	]:
		var stray := MeshInstance3D.new()
		stray.mesh = stray_mesh
		stray.position = stray_data[0]
		stray.rotation.y = stray_data[1]
		stray.rotation.z = 0.02
		_deck.add_child(stray)

	# Fireflies: two slow drifting layers.
	for firefly_data in [
		[Color(0.95, 0.9, 0.45, 0.9), 26, 0.05],
		[Color(0.5, 0.95, 0.6, 0.6), 16, 0.08],
	]:
		var quad := QuadMesh.new()
		quad.size = Vector2(firefly_data[2], firefly_data[2])
		var glow := StandardMaterial3D.new()
		glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.albedo_color = firefly_data[0]
		glow.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		quad.material = glow
		var flies := CPUParticles3D.new()
		flies.mesh = quad
		flies.amount = firefly_data[1]
		flies.lifetime = 7.0
		flies.preprocess = 7.0
		flies.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		flies.emission_box_extents = Vector3(2.4, 1.6, 1.2)
		flies.position = Vector3(0, 1.4, 0.5)
		flies.direction = Vector3(0, 1, 0)
		flies.spread = 180.0
		flies.gravity = Vector3.ZERO
		flies.initial_velocity_min = 0.05
		flies.initial_velocity_max = 0.25
		flies.color = firefly_data[0]
		add_child(flies)

	# Grounding floor + lights (position-only, no rotation).
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(10, 7)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.13, 0.13, 0.17)
	floor_mat.roughness = 0.9
	floor_mesh.material = floor_mat
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	add_child(floor_node)

	var key := OmniLight3D.new()
	key.position = Vector3(0.5, 4.0, 3.0)
	key.light_color = Color(1, 0.92, 0.8)
	key.light_energy = 1.5
	key.omni_range = 14.0
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-2.0, 2.0, 1.5)
	fill.light_color = Color(0.5, 0.6, 1.0)
	fill.light_energy = 0.9
	fill.omni_range = 9.0
	add_child(fill)


# =====================================================================
# UI layer
# =====================================================================

func _build_ui() -> void:
	var ui := CanvasLayer.new()
	ui.layer = 1
	add_child(ui)

	var story := _make_button(ui, "STORY MODE", Vector2(90, 1440), Vector2(430, 120), 40)
	story.pressed.connect(func() -> void:
		Sfx.play(&"ui_click")
		get_tree().change_scene_to_file(MATCH_SCENE))

	var online := _make_button(ui, "ONLINE MATCH", Vector2(560, 1440), Vector2(430, 120), 40)
	online.disabled = true
	online.tooltip_text = "Coming with the Nakama sprint"
	online.modulate = Color(0.7, 0.7, 0.75)

	var labels: Array[String] = ["DECKS", "INVENTORY", "SHOP"]
	for i in 3:
		var placeholder := _make_button(ui, labels[i], Vector2(90 + 313.0 * float(i), 1590), Vector2(287, 92), 28)
		placeholder.disabled = true
		placeholder.modulate = Color(0.62, 0.62, 0.68)

	# Settings gear, top-right.
	var gear := Button.new()
	gear.position = Vector2(960, 36)
	gear.size = Vector2(90, 90)
	gear.flat = true
	var icon := GearIcon.new()
	icon.size = Vector2(90, 90)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gear.add_child(icon)
	gear.pressed.connect(func() -> void:
		Sfx.play(&"ui_click")
		var menu: Node = get_node_or_null("SettingsMenu")
		if menu != null:
			menu.open())
	ui.add_child(gear)


func _make_button(ui: CanvasLayer, label: String, pos: Vector2, btn_size: Vector2, font_size: int) -> Button:
	var button := Button.new()
	button.text = label
	button.position = pos
	button.size = btn_size
	button.add_theme_font_size_override(&"font_size", font_size)
	ui.add_child(button)
	return button
