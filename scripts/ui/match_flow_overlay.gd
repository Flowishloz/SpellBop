## match_flow_overlay.gd — Round banners + the victory screen.
##
## PURE PRESENTATION, wall-clock animated (the UI exception: immune to the
## Stack's time dilation AND to the parked sim between rounds). Reads ONLY
## MatchController's round-flow signals.
##
## States:
##   - ROUND BANNER (post-round break): "ROUND TAKEN/LOST" + score + a live
##     countdown to the next round, over a soft dim. The card hand expands
##     beside it (CardHandHUD handles that).
##   - VICTORY SCREEN (match over): full dim, verdict, score, rematch hint.
extends CanvasLayer

## The MatchController whose signals drive this overlay.
@export var match_controller_path: NodePath = NodePath("..")

@export var win_color: Color = Color(0.95, 0.85, 0.4)
@export var lose_color: Color = Color(0.85, 0.3, 0.3)

var _dim: ColorRect
var _title: Label
var _score: Label
var _stats_panel: Panel
var _stats_header: Label
var _stat_lines: Array[Label] = []
var _hint: Label
var _play_again: Button       # match-end only: restarts the match
var _mc: Node                 # the MatchController (rematch target)
var _break_deadline_msec: int = 0
var _showing_break: bool = false
# ROUND-N call-out (Phase 3): a bold popped title framed by horizontal lightning.
var _round_label: Label
var _round_lightning: _RoundLightning
var _round_anim_msec: int = 0  # wall-clock start of the round call-out (0 = idle)

# Match-end podium (built once, hidden until victory/defeat).
var _podium: Control
var _win_box: ColorRect
var _lose_box: ColorRect
var _win_sprite: TextureRect
var _lose_sprite: TextureRect
var _confetti: CPUParticles2D


func _ready() -> void:
	layer = 3  # above the HUD layers

	_dim = ColorRect.new()
	_dim.color = Color(0.0, 0.0, 0.05, 0.0)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	_title = _make_label(64, Vector2(0, 360))
	_score = _make_label(40, Vector2(0, 460))

	# MATCH STATS — their own framed section (Creative Director), above the
	# horizontal card row the hand HUD lays out at the bottom.
	_stats_panel = Panel.new()
	_stats_panel.position = Vector2(110, 580)
	_stats_panel.size = Vector2(860, 330)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.11, 0.92)
	style.border_color = Color(0.85, 0.75, 0.45, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(16)
	_stats_panel.add_theme_stylebox_override(&"panel", style)
	add_child(_stats_panel)
	_stats_header = Label.new()
	_stats_header.text = "MATCH STATS"
	_stats_header.position = Vector2(0, 14)
	_stats_header.size = Vector2(860, 44)
	_stats_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_header.add_theme_font_size_override(&"font_size", 30)
	_stats_header.add_theme_color_override(&"font_color", Color(0.95, 0.85, 0.5))
	_stats_panel.add_child(_stats_header)
	for i in 3:
		var line := Label.new()
		line.position = Vector2(0, 86 + i * 74)
		line.size = Vector2(860, 60)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.add_theme_font_size_override(&"font_size", 30)
		_stats_panel.add_child(line)
		_stat_lines.append(line)

	_hint = _make_label(28, Vector2(0, 950))

	# ROUND-N CALL-OUT (Phase 3): a dedicated BOLD label (kept off _title so the
	# result screens keep their own size) framed by two horizontal lightning bolts.
	_round_lightning = _RoundLightning.new()
	_round_lightning.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_round_lightning.visible = false
	add_child(_round_lightning)
	_round_label = Label.new()
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_label.size = Vector2(1080, 130)
	_round_label.position = Vector2(0, 720)
	_round_label.pivot_offset = Vector2(540, 65)
	_round_label.add_theme_font_size_override(&"font_size", 104)
	_round_label.add_theme_color_override(&"font_color", Color(1, 1, 1))
	_round_label.add_theme_color_override(&"font_outline_color", Color(0.1, 0.2, 0.45, 0.95))
	_round_label.add_theme_constant_override(&"outline_size", 16)
	_round_label.visible = false
	add_child(_round_label)

	# PLAY AGAIN button — the post-match restart (replaces "tap the fireball").
	# Sits just under the stats panel; shown only on the match-end screen.
	_play_again = Button.new()
	_play_again.text = "PLAY AGAIN"
	_play_again.size = Vector2(420, 110)
	_play_again.position = Vector2((1080 - 420) / 2.0, 1340)
	_play_again.add_theme_font_size_override(&"font_size", 44)
	_style_play_again_button()
	_play_again.pressed.connect(_on_play_again_pressed)
	_play_again.visible = false
	add_child(_play_again)

	_build_podium()
	_set_visible_state(false)

	_mc = get_node_or_null(match_controller_path)
	if _mc == null:
		push_warning("MatchFlowOverlay: MatchController not found — overlay inert.")
		return
	_mc.round_started.connect(_on_round_started)
	_mc.round_ended.connect(_on_round_ended)
	_mc.match_ended.connect(_on_match_ended)


func _make_label(font_size: int, pos: Vector2) -> Label:
	# Explicit geometry, no anchor presets: presets applied before parenting
	# recompute offsets on tree entry and shoved the banner off-center
	# (caught by the screenshot probe). Canvas space is a stable 1080x1920
	# under the canvas_items stretch, so absolute coords are safe.
	var label := Label.new()
	label.position = pos
	label.size = Vector2(1080, font_size + 24)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override(&"outline_size", 8)
	add_child(label)
	return label


## Match-end podium: winner stands taller under raining confetti; the loser
## takes the short box. Sprites are decided at show time.
func _build_podium() -> void:
	_podium = Control.new()
	_podium.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_podium)

	_win_box = ColorRect.new()
	_win_box.color = Color(0.8, 0.7, 0.35)
	_win_box.position = Vector2(560, 660)
	_win_box.size = Vector2(240, 270)
	_podium.add_child(_win_box)

	_lose_box = ColorRect.new()
	_lose_box.color = Color(0.4, 0.4, 0.48)
	_lose_box.position = Vector2(290, 790)
	_lose_box.size = Vector2(220, 140)
	_podium.add_child(_lose_box)

	_win_sprite = TextureRect.new()
	_win_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_win_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_win_sprite.position = Vector2(600, 330)
	_win_sprite.size = Vector2(160, 320)
	_podium.add_child(_win_sprite)

	_lose_sprite = TextureRect.new()
	_lose_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_lose_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_lose_sprite.position = Vector2(330, 530)
	_lose_sprite.size = Vector2(130, 250)
	_podium.add_child(_lose_sprite)

	_confetti = CPUParticles2D.new()
	_confetti.position = Vector2(680, 250)
	_confetti.amount = 50
	_confetti.lifetime = 2.4
	_confetti.preprocess = 1.0
	_confetti.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_confetti.emission_rect_extents = Vector2(220, 8)
	_confetti.direction = Vector2(0, 1)
	_confetti.spread = 20.0
	_confetti.gravity = Vector2(0, 360)
	_confetti.initial_velocity_min = 30.0
	_confetti.initial_velocity_max = 110.0
	_confetti.scale_amount_min = 5.0
	_confetti.scale_amount_max = 9.0
	_confetti.angle_min = -180.0
	_confetti.angle_max = 180.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.3))
	ramp.set_color(1, Color(0.4, 0.7, 1.0))
	ramp.add_point(0.5, Color(1.0, 0.45, 0.6))
	_confetti.color_initial_ramp = ramp
	_podium.add_child(_confetti)
	_podium.visible = false


func _process(_delta: float) -> void:
	if _round_anim_msec != 0:
		_animate_round_call()

	if not _showing_break:
		return
	var remaining: float = maxf(0.0, float(_break_deadline_msec - Time.get_ticks_msec()) / 1000.0)
	_hint.text = "next round in %d..." % ceili(remaining)


## Drives the ROUND-N pop + lightning shoot on the wall clock (immune to the
## parked sim / dilation): pop (scale), bolt shoot (t), flash, hold, then fade.
func _animate_round_call() -> void:
	var rt: float = float(Time.get_ticks_msec() - _round_anim_msec) / 1000.0
	if rt >= 1.95:
		_end_round_call()
		return
	_round_label.scale = Vector2.ONE * lerpf(1.5, 1.0, ease(clampf(rt / 0.3, 0.0, 1.0), 0.32))
	_round_lightning.t = clampf(rt / 0.22, 0.0, 1.0)
	_round_lightning.flash = clampf(1.0 - rt / 0.55, 0.0, 1.0)
	var a: float = 1.0 if rt < 1.3 else clampf(1.0 - (rt - 1.3) / 0.6, 0.0, 1.0)
	_round_label.modulate.a = a
	_round_lightning.modulate.a = a
	_round_lightning.queue_redraw()


func _end_round_call() -> void:
	_round_anim_msec = 0
	if _round_label != null:
		_round_label.visible = false
	if _round_lightning != null:
		_round_lightning.visible = false


func _on_round_started(round_number: int) -> void:
	_showing_break = false
	_set_visible_state(false)
	# BOLD round call-out (Phase 3): the number POPS in framed by horizontal
	# lightning (top bolt shoots right, bottom bolt shoots left), then fades.
	_round_label.text = "ROUND %d" % round_number
	_round_label.modulate = Color.WHITE
	_round_label.scale = Vector2(1.5, 1.5)
	_round_label.visible = true
	_round_lightning.position = Vector2(0, _round_label.position.y - 18.0)
	_round_lightning.size = Vector2(1080, _round_label.size.y + 36.0)
	_round_lightning.modulate = Color.WHITE
	_round_lightning.seed_v = round_number * 7919 + 13
	_round_lightning.t = 0.0
	_round_lightning.flash = 1.0
	_round_lightning.visible = true
	_round_lightning.queue_redraw()
	_round_anim_msec = Time.get_ticks_msec()


## A still-running ROUND-N fade must never eat the result screens' title
## (caught by the screenshot audit: a KO within ~2 s of a round start let
## the stale tween fade "VICTORY" to invisible).
func _kill_callout() -> void:
	# A KO within ~2 s of a round start must not let the stale ROUND-N call-out
	# linger over the result screen — stop it immediately.
	_end_round_call()


func _on_round_ended(player_won_round: bool, player_score: int, opponent_score: int, break_seconds: float) -> void:
	_kill_callout()
	_showing_break = true
	_break_deadline_msec = Time.get_ticks_msec() + int(break_seconds * 1000.0)
	_set_visible_state(true)
	_podium.visible = false
	_title.position.y = 360
	_score.position.y = 460
	_stats_panel.position = Vector2(110, 580)
	_hint.position.y = 950
	_dim.color = Color(0.0, 0.0, 0.05, 0.55)
	_title.modulate = Color.WHITE
	_title.text = "ROUND TAKEN" if player_won_round else "ROUND LOST"
	_title.add_theme_color_override(&"font_color", win_color if player_won_round else lose_color)
	_score.text = "YOU %d  -  %d FOE" % [player_score, opponent_score]
	_fill_stats()
	_hint.text = ""
	_play_again.visible = false  # round breaks aren't restartable — match-end only


func _on_match_ended(player_won_match: bool) -> void:
	_kill_callout()
	_showing_break = false
	_set_visible_state(true)
	_dim.color = Color(0.0, 0.0, 0.05, 0.88)
	_title.position.y = 140
	_score.position.y = 232
	_stats_panel.position = Vector2(110, 980)
	_hint.position.y = 1330
	_title.modulate = Color.WHITE
	_title.text = "VICTORY" if player_won_match else "DEFEAT"
	_title.add_theme_color_override(&"font_color", win_color if player_won_match else lose_color)
	if _mc != null:
		_score.text = "YOU %d  -  %d FOE" % [_mc.player_score, _mc.opponent_score]
	_fill_stats()
	_hint.text = ""
	# The PLAY AGAIN button (under the stats) is the restart trigger now.
	_play_again.visible = true

	# PODIUM: winner up high under the confetti rain.
	_podium.visible = true
	var blue: Texture2D = load("res://resources/placeholder/wizard_blue.png")
	var red: Texture2D = load("res://resources/placeholder/wizard_red.png")
	_win_sprite.texture = blue if player_won_match else red
	_lose_sprite.texture = red if player_won_match else blue
	_confetti.restart()
	_confetti.emitting = true


func _on_play_again_pressed() -> void:
	if _mc != null and _mc.has_method(&"request_rematch"):
		_mc.request_rematch()


## Gold-bordered styling for the PLAY AGAIN button (matches the stats panel).
func _style_play_again_button() -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.12, 0.18, 0.96)
	normal.border_color = Color(0.95, 0.82, 0.4, 0.95)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(16)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.22, 0.19, 0.1, 0.98)
	hover.border_color = Color(1.0, 0.9, 0.55, 1.0)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.08, 0.08, 0.12, 1.0)
	_play_again.add_theme_stylebox_override(&"normal", normal)
	_play_again.add_theme_stylebox_override(&"hover", hover)
	_play_again.add_theme_stylebox_override(&"pressed", pressed)
	_play_again.add_theme_stylebox_override(&"focus", normal)
	_play_again.add_theme_color_override(&"font_color", Color(0.97, 0.92, 0.7))
	_play_again.add_theme_color_override(&"font_hover_color", Color(1, 1, 1))


## Fills the framed stats section from MatchController.get_stats().
func _fill_stats() -> void:
	var mc: Node = get_node_or_null(match_controller_path)
	if mc == null or not mc.has_method(&"get_stats"):
		for line in _stat_lines:
			line.text = ""
		return
	var s: Dictionary = mc.get_stats()
	_stat_lines[0].text = "LIFE LEFT      you %d   •   foe %d" % [s["own_hp"], s["foe_hp"]]
	_stat_lines[1].text = "ACCURACY      %d%%   (%d of %d throws landed)" % [s["accuracy"], s["hits"], s["throws"]]
	_stat_lines[2].text = "DAMAGE        dealt %d   •   taken %d" % [s["damage_dealt"], s["damage_taken"]]


## Two horizontal lightning bolts framing the ROUND-N call-out: the TOP bolt
## shoots RIGHT (grows from the left edge), the BOTTOM bolt shoots LEFT (grows
## from the right edge). `t` = 0..1 shoot progress, `flash` = 0..1 bloom. The
## jagged shape is seeded per round so it is stable during the animation.
class _RoundLightning extends Control:
	var t: float = 1.0
	var flash: float = 0.0
	var seed_v: int = 0
	var bolt_color: Color = Color(0.55, 0.8, 1.0)
	var jitter_height: float = 18.0

	func _draw() -> void:
		_bolt(16.0, true, seed_v)                    # top bolt -> shoots right
		_bolt(size.y - 16.0, false, seed_v + 4099)   # bottom bolt -> shoots left

	func _bolt(y: float, going_right: bool, seed_value: int) -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var segs: int = 22
		var jit := PackedFloat32Array()
		for i in segs + 1:
			jit.append(rng.randf_range(-jitter_height, jitter_height))
		var drawn: float = size.x * clampf(t, 0.0, 1.0)
		var pts := PackedVector2Array()
		for i in segs + 1:
			var fx: float = size.x * float(i) / float(segs)
			if going_right:
				if fx > drawn:
					break
			elif fx < size.x - drawn:
				continue
			pts.append(Vector2(fx, y + jit[i]))
		if pts.size() < 2:
			return
		var glow := Color(bolt_color.r, bolt_color.g, bolt_color.b, 0.3 + 0.55 * flash)
		var core := Color(1.0, 1.0, 1.0, 0.85)
		draw_polyline(pts, glow, 9.0 + 7.0 * flash, true)
		draw_polyline(pts, core, 3.5, true)


func _set_visible_state(shown: bool) -> void:
	_dim.visible = shown
	_title.visible = shown
	_score.visible = shown
	_stats_panel.visible = shown
	_hint.visible = shown
	if not shown:
		_dim.color.a = 0.0
		if _play_again != null:
			_play_again.visible = false
		if _podium != null:
			_podium.visible = false
			_confetti.emitting = false
