## stack_display_hud.gd — THE STACK, on screen (MTG-style).
##
## PURE PRESENTATION, wall-clock springs. Whenever EITHER wizard stages a
## spell (spell_staged from any CardCasterComponent), a large legible card
## face SLAPS onto the top-center of the screen: it flies in from the
## caster's side very fast with overshoot and a scale punch — slow-in,
## slow-out, violent in between, like a card slammed on a table. A counter
## staged in response lands slightly OVERLAPPING the spell below it (offset
## + opposing tilt), and the shared countdown label always rides the TOP
## card. When the window expires (the stack resolves) every face flies up
## and fades.
##
## The size is deliberately large (300x190-ish text zone): the DEFENDER must
## be able to read the incoming attack and decide whether to counter.
extends CanvasLayer

## Both wizards' card casters (player first — its slaps fly in from the
## bottom-right hand; the opponent's drop in from the top).
@export var player_caster_path: NodePath = NodePath("../Player/CardCasterComponent")
@export var opponent_caster_path: NodePath = NodePath("../Opponent/CardCasterComponent")

## The MatchController (for the stack-winner indicator signal).
@export var match_controller_path: NodePath = NodePath("..")

## Stack anchor (canvas px) for the FIRST card; later slaps offset from it.
## SPRINT 22 (Creative Director): moved to the RIGHT side (was centred at x=540) so the
## stack no longer covers the opponent after the camera reposition.
@export var stack_center: Vector2 = Vector2(820, 300)

## Card face size at the stack (big and readable). SPRINT 22: shrunk 20% (was 330x440)
## to clear central screen space.
@export var card_size: Vector2 = Vector2(264, 352)

## Slap spring: very stiff + underdamped = fast travel, smack, tiny settle.
@export var slap_stiffness: float = 900.0
@export var slap_damping: float = 24.0

const TYPE_COLORS: Array[Color] = [
	Color(0.85, 0.25, 0.2),
	Color(0.25, 0.7, 0.4),
	Color(0.3, 0.55, 0.95),
]
const TYPE_NAMES: Array[String] = ["ATTACK", "DEFENSE", "COUNTER"]
## Same bespoke art as the hand (consistency: on the stack, ART + TEXT).
const TYPE_ART: Array[String] = [
	"res://resources/placeholder/spark_icon.png",
	"res://resources/placeholder/shield_icon.png",
	"res://resources/placeholder/ice_icon.png",
]

# One entry per staged spell: {face, pos, vel, rot, rot_vel, scale,
# scale_vel, target_pos, target_rot, leaving}.
var _entries: Array[Dictionary] = []
var _countdown: Label
var _countdown_base: Vector2 = Vector2.ZERO
var _root: Control
var _stack: Node
var _last_msec: int = 0
var _last_tick_second: int = -1  # stopwatch cue edge tracker
var _winner_label: Label         # "YOU/FOE WIN THE STACK" flash
var _winner_msec: int = 0        # wall-clock start of the winner flash (0 = idle)
var _winner_is_player: bool = true


func _ready() -> void:
	layer = 2
	_last_msec = Time.get_ticks_msec()

	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# RAISED countdown (Creative Director: the slapped cards covered it) —
	# fixed high-center spot, always drawn ABOVE the card faces (re-fronted
	# after every slap), shaking harder as it approaches zero.
	_countdown = Label.new()
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.size = Vector2(240, 80)
	_countdown.add_theme_font_size_override(&"font_size", 64)
	_countdown.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	_countdown.add_theme_constant_override(&"outline_size", 12)
	_countdown.visible = false
	_root.add_child(_countdown)
	_countdown_base = Vector2(stack_center.x - 120.0, 36.0)
	_countdown.position = _countdown_base

	var player_caster: Node = get_node_or_null(player_caster_path)
	if player_caster != null:
		player_caster.spell_staged.connect(_on_staged.bind(true))
	var opponent_caster: Node = get_node_or_null(opponent_caster_path)
	if opponent_caster != null:
		opponent_caster.spell_staged.connect(_on_staged.bind(false))

	_stack = get_node_or_null(^"/root/TheStack")
	if _stack != null:
		_stack.stack_tick.connect(_on_stack_tick)
		_stack.stack_closed.connect(_on_stack_closed)

	# STACK WINNER INDICATOR (Phase 3): a bold banner flashes who won the stack
	# (the last responder) the instant it resolves — MatchController decides it.
	_winner_label = Label.new()
	_winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_label.size = Vector2(1080, 90)
	_winner_label.position = Vector2(0, 470)
	_winner_label.pivot_offset = Vector2(540, 45)
	_winner_label.add_theme_font_size_override(&"font_size", 58)
	_winner_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.95))
	_winner_label.add_theme_constant_override(&"outline_size", 12)
	_winner_label.visible = false
	_root.add_child(_winner_label)
	var mc: Node = get_node_or_null(match_controller_path)
	if mc != null and mc.has_signal(&"stack_winner_decided"):
		mc.stack_winner_decided.connect(_on_stack_winner)


func _on_staged(card: CardResource, from_player: bool) -> void:
	# A card landing ON TOP of another gets the extra card-on-card slap.
	if not _entries.is_empty():
		Sfx.play(&"slap_on_card")
	var face: Control = _build_face(card, from_player)
	_root.add_child(face)
	# Keep the countdown above every slapped face.
	_root.move_child(_countdown, _root.get_child_count() - 1)
	var index: int = _entries.size()
	# Slapped on the pile: each response lands lower-right of the spell it
	# answers, tilted the other way — like cards smacked on a table.
	var target: Vector2 = stack_center + Vector2(27.0 * index, 32.0 * index)
	# Player slaps fly in from the HAND side (mirrored in left-handed mode).
	var settings: Node = get_node_or_null(^"/root/GameSettings")
	var hand_x: float = 980.0
	if settings != null and settings.left_handed:
		hand_x = 100.0
	var start: Vector2 = Vector2(hand_x, 1500) if from_player else Vector2(stack_center.x, -400)
	_entries.append({
		"face": face,
		"pos": start,
		"vel": Vector2.ZERO,
		"rot": deg_to_rad(25.0 if from_player else -20.0),
		"rot_vel": 0.0,
		"scale": 1.45,
		"scale_vel": 0.0,
		"target_pos": target,
		"target_rot": deg_to_rad((-5.0 if index % 2 == 0 else 6.0) * (1.0 if index > 0 else 0.4)),
		"leaving": false,
		"glow_color": TYPE_COLORS[clampi(card.card_type, 0, 2)] if card != null else Color(1, 1, 1),
	})
	_countdown.visible = true


func _on_stack_tick(remaining_s: float) -> void:
	_countdown.text = "%.1f" % remaining_s
	# Stopwatch cue at DOUBLE rate (Creative Director): one tick per half
	# second of the countdown.
	var half_second: int = ceili(remaining_s * 2.0)
	if half_second != _last_tick_second and remaining_s > 0.05 and _countdown.visible:
		_last_tick_second = half_second
		Sfx.play(&"stopwatch_tick")


## The window closed: the whole stack resolves AT ONCE (Creative Director playtest
## preference). Every staged card face flies up and fades together, in lockstep
## with the simultaneous projectile releases.
func _on_stack_closed() -> void:
	_countdown.visible = false
	_last_tick_second = -1
	for entry in _entries:
		entry["leaving"] = true
		entry["target_pos"] = (entry["pos"] as Vector2) + Vector2(0, -700)
		entry["vel"] = (entry["vel"] as Vector2) + Vector2(0, -900)


## STACK WINNER (Phase 3): flash a bold banner naming the winner (the last
## responder) the instant the stack resolves. Triggered by MatchController.
func _on_stack_winner(player_won: bool) -> void:
	_winner_is_player = player_won
	_winner_msec = Time.get_ticks_msec()
	_winner_label.text = "YOU WIN THE STACK!" if player_won else "FOE WINS THE STACK"
	_winner_label.add_theme_color_override(&"font_color",
			Color(1.0, 0.9, 0.4) if player_won else Color(1.0, 0.45, 0.4))
	_winner_label.visible = true


## Animates the winner banner: a scale punch in, hold, then fade over ~1.4 s of
## wall clock (immune to dilation, like the rest of this HUD).
func _update_winner_flash(now: int) -> void:
	if _winner_msec == 0:
		return
	var t: float = float(now - _winner_msec) / 1000.0
	if t >= 1.4:
		_winner_label.visible = false
		_winner_msec = 0
		return
	var s: float = 1.0
	if t < 0.18:
		s = 0.4 + 1.0 * (t / 0.18)            # 0.4 -> 1.4 punch in
	elif t < 0.34:
		s = 1.4 - 0.4 * ((t - 0.18) / 0.16)   # 1.4 -> 1.0 settle
	var alpha: float = 1.0 if t < 1.0 else (1.0 - (t - 1.0) / 0.4)
	_winner_label.scale = Vector2.ONE * s
	_winner_label.modulate.a = clampf(alpha, 0.0, 1.0)


func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_msec()
	var dt: float = clampf(float(now - _last_msec) / 1000.0, 0.0, 0.05)
	_last_msec = now

	_update_winner_flash(now)

	if dt <= 0.0 or _entries.is_empty():
		return

	# FRANTIC WOA SHAKE: as the countdown approaches zero, the top card and
	# the timer shake harder and faster — telegraphing that a counter cast
	# NOW lands at maximum Window-of-Affect strength.
	var franticness: float = 0.0
	if _stack != null and _countdown.visible:
		var fraction: float = _stack.window_fraction_remaining()
		franticness = (1.0 - fraction) * (1.0 - fraction)
	var wobble_t: float = float(now) / 1000.0 * (9.0 + 26.0 * franticness)
	var shake: Vector2 = Vector2(
			sin(wobble_t * 1.9), sin(wobble_t * 2.7 + 1.2)) * 13.0 * franticness
	_countdown.position = _countdown_base + shake * 1.4
	_countdown.add_theme_color_override(&"font_color",
			Color(1.0, 1.0 - 0.7 * franticness, 1.0 - 0.8 * franticness))

	var finished: Array[Dictionary] = []
	for entry in _entries:
		var pos: Vector2 = entry["pos"]
		var vel: Vector2 = entry["vel"]
		vel += (entry["target_pos"] as Vector2 - pos) * slap_stiffness * dt
		vel *= maxf(0.0, 1.0 - slap_damping * dt)
		pos += vel * dt
		entry["pos"] = pos
		entry["vel"] = vel

		var rot: float = entry["rot"]
		var rot_vel: float = entry["rot_vel"]
		rot_vel += (entry["target_rot"] as float - rot) * slap_stiffness * dt
		rot_vel *= maxf(0.0, 1.0 - slap_damping * dt)
		rot += rot_vel * dt
		entry["rot"] = rot
		entry["rot_vel"] = rot_vel

		# Scale punch: lands big, settles to 1 (impact read).
		var scale: float = entry["scale"]
		var scale_vel: float = entry["scale_vel"]
		scale_vel += (1.0 - scale) * slap_stiffness * dt
		scale_vel *= maxf(0.0, 1.0 - slap_damping * dt)
		scale += scale_vel * dt
		entry["scale"] = scale
		entry["scale_vel"] = scale_vel

		var face: Control = entry["face"]
		var leaving: bool = entry["leaving"]
		var is_top: bool = entry == _entries[_entries.size() - 1] and not leaving
		# Phase 3: ALL staged (attack/counter) cards shake — harder on the top
		# card — and GLOW their type colour, intensifying as the timer runs down.
		var card_shake: Vector2 = Vector2.ZERO if leaving else shake * (1.0 if is_top else 0.6)
		face.position = pos - card_size * 0.5 + card_shake
		face.rotation = rot + (0.012 * sin(wobble_t * 3.1) * (1.0 if is_top else 0.5) * franticness * 8.0)
		face.scale = Vector2.ONE * scale
		if leaving:
			face.modulate.a = maxf(0.0, face.modulate.a - 3.0 * dt)
			if face.modulate.a <= 0.0:
				finished.append(entry)
		else:
			# Glow toward the type colour (components above 1.0 = bloom), growing
			# with franticness; alpha stays full.
			var gc: Color = entry["glow_color"]
			var g: float = 0.85 * franticness
			face.modulate = Color(1.0 + gc.r * g, 1.0 + gc.g * g, 1.0 + gc.b * g, 1.0)

	for entry in finished:
		(entry["face"] as Control).queue_free()
		_entries.erase(entry)


## A stack face MIRRORS its in-round hand counterpart (Creative Director):
## frame (owner-colored border), type header, ART, rune glyphs — NO text.
## Rules text lives only between rounds / on the post-match screen.
func _build_face(card: CardResource, from_player: bool) -> Control:
	var face := Panel.new()
	face.size = card_size
	face.pivot_offset = card_size * 0.5
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.12, 0.97)
	style.border_color = Color(0.95, 0.85, 0.5, 1.0) if from_player else Color(0.9, 0.45, 0.4, 1.0)
	style.set_border_width_all(4)
	style.set_corner_radius_all(14)
	face.add_theme_stylebox_override(&"panel", style)

	var type_idx: int = clampi(card.card_type, 0, 2) if card != null else 0
	var header := ColorRect.new()
	header.color = TYPE_COLORS[type_idx]
	header.position = Vector2(8, 8)
	header.size = Vector2(card_size.x - 16, 56)
	face.add_child(header)

	# Rune "name" in the header — same glyph script as the hand card.
	var runes := CardHandRunes.new()
	runes.seed_value = (card.display_name if card != null else "x").hash()
	runes.position = Vector2(16, 14)
	runes.size = Vector2(card_size.x - 32, 44)
	runes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(runes)

	# Full-strength art fills the body (the art IS the telegraph).
	var art := TextureRect.new()
	art.texture = load(TYPE_ART[type_idx])
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.position = Vector2(40, 84)
	art.size = Vector2(card_size.x - 80, card_size.y - 124)
	face.add_child(art)

	return face


## Same deterministic pixel-glyph strip the hand uses (duplicated locally —
## sized for the larger stack header).
class CardHandRunes extends Control:
	var seed_value: int = 0

	func _draw() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var x: float = 4.0
		while x < size.x - 18.0:
			var glyph_w: float = rng.randf_range(11.0, 20.0)
			var strokes: int = rng.randi_range(2, 4)
			for s in strokes:
				var ink := Color(0.05, 0.05, 0.1, 0.75)
				if rng.randf() < 0.5:
					draw_rect(Rect2(x + rng.randf_range(0, glyph_w - 5), rng.randf_range(3, size.y - 13), 5, rng.randf_range(7, size.y - 10)), ink)
				else:
					draw_rect(Rect2(x, rng.randf_range(4, size.y - 9), glyph_w, 5), ink)
			x += glyph_w + 9.0
