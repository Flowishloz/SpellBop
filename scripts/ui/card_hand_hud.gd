## card_hand_hud.gd — The player's hand: 3 cards fanned at the screen edge.
##
## PURE PRESENTATION, wall-clock spring animation throughout (the UI
## exception — immune to the Stack's 10% dilation, and springs give the hand
## MOMENTUM: it lags, overshoots and settles instead of snapping).
##
## STATES (Creative Director, stack-rework sprint):
##   DOCKED   — tilted sideways, fanned like a held hand, mostly tucked
##              behind the right screen edge. Only type color + cost pips
##              read at a glance (Cards_Spells.txt §6 minimal state). Cards
##              on COOLDOWN dim until ready.
##   CHARGING — the held card swells, lifts above its siblings and slides
##              into view while the channel runs (reveal = progress).
##   (STAGED) — the card LEAVES THE HAND: it vanishes here and SLAPS onto
##              the shared StackDisplayHUD at the top (both players' staged
##              spells live there). It returns to the dock at resolution.
##   EXPANDED — post-round break: all three glide to center stage, larger,
##              with full rules text + damage (the 15 s study phase).
##   REJECTED — reactive-lock / cooldown refusal: a quick sideways shake
##              (kick decays through the spring — follow-through for free).
##
## ANIMATION PRINCIPLES used: slow-in/slow-out + follow-through come from
## underdamped springs; anticipation is an explicit counter-kick before big
## moves; squash & stretch is kept minimal (scale pulse on the charging
## card). The hand root also SWAYS against the camera pan like the health
## bar — nothing in this HUD is glued in place.
extends CanvasLayer

## The player's CardCasterComponent (signal source).
@export var card_caster_path: NodePath = NodePath("../Player/CardCasterComponent")

## The MatchController (round flow signals for the expanded state).
@export var match_controller_path: NodePath = NodePath("..")

## Card face size (canvas px) at scale 1.
@export var card_size: Vector2 = Vector2(240, 340)

## Spring feel (underdamped = overshoot/follow-through).
@export var spring_stiffness: float = 140.0
@export var spring_damping: float = 11.0

## Hand-root sway against camera pan (px per meter).
@export var sway_per_meter: float = 18.0

## CONDITIONAL CARDS (Sprint 23 batch 3, Creative Director): the COUNTER (blue) card only appears
## when a spell is on the stack, and the DEFENSE (green) card only when an attack is incoming within
## this range (sim units) — each POPS into the hand on its cue instead of always sitting in the fan.
@export var defense_threat_range: float = 650.0

## DEFENSE PREDICT (Sprint 23 batch 3 follow-up, Creative Director): pop the DEFENSE card in EARLY —
## while a staged attack is still on the stack with this many seconds (or fewer) left on the countdown
## — so there's time to ready a block on mobile (instead of waiting for the spell to resolve + the
## projectile to physically close in). The incoming-ball scan stays as a fallback for the direct
## fireball, which never goes on the stack.
@export var defense_predict_seconds: float = 0.8

const TYPE_COLORS: Array[Color] = [
	Color(0.85, 0.25, 0.2),   # ATTACK — red
	Color(0.25, 0.7, 0.4),    # DEFENSE — green
	Color(0.3, 0.55, 0.95),   # COUNTER — blue
]
const TYPE_NAMES: Array[String] = ["ATTACK", "DEFENSE", "COUNTER"]
## Bespoke per-type art (the art IS the in-round message): spark / shield / ice.
const TYPE_ART: Array[String] = [
	"res://resources/placeholder/spark_icon.png",
	"res://resources/placeholder/shield_icon.png",
	"res://resources/placeholder/ice_icon.png",
]

enum CardState { DOCKED, CHARGING, EXPANDED }


## Vague pixelated hieroglyphs where a card name would read (Creative
## Director: nobody reads during rounds — the runes are pure flavor).
## Deterministically seeded by the card name so each card keeps its "script".
class RuneStrip extends Control:
	var seed_value: int = 0

	func _draw() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var x: float = 4.0
		while x < size.x - 14.0:
			var glyph_w: float = rng.randf_range(8.0, 15.0)
			var strokes: int = rng.randi_range(2, 4)
			for s in strokes:
				var ink := Color(0.05, 0.05, 0.1, 0.75)
				if rng.randf() < 0.5:
					draw_rect(Rect2(x + rng.randf_range(0, glyph_w - 4), rng.randf_range(2, size.y - 10), 4, rng.randf_range(5, size.y - 8)), ink)
				else:
					draw_rect(Rect2(x, rng.randf_range(3, size.y - 7), glyph_w, 4), ink)
			x += glyph_w + 7.0

var _root: Control
var _cards: Array[Control] = []
var _desc_labels: Array[Label] = []
var _info_labels: Array[Array] = []     # per-card text shown only EXPANDED
var _art_rects: Array[TextureRect] = [] # per-card art (fades under text)
var _rune_strips: Array[Control] = []   # in-round hieroglyph "names"
var _counter_slot: int = -1             # slot index of the reactive card
var _stack: Node = null
var _states: Array[int] = [CardState.DOCKED, CardState.DOCKED, CardState.DOCKED]
# Per-card availability (index 0 ATTACK always; 1 DEFENSE on an incoming attack; 2 COUNTER on a
# spell on the stack). An unavailable card shrinks out of the hand; it POPS back in on its cue.
var _available: Array[bool] = [true, false, false]
var _expanded: bool = false

# Per-card spring state (positions are CENTERS; rendering subtracts half).
var _pos: Array[Vector2] = []
var _pos_vel: Array[Vector2] = []
var _rot: Array[float] = []
var _rot_vel: Array[float] = []
var _scale: Array[float] = []
var _scale_vel: Array[float] = []

var _root_offset: Vector2 = Vector2.ZERO
var _root_vel: Vector2 = Vector2.ZERO
var _camera: Camera3D
var _cam_base_x: float = 0.0
var _last_msec: int = 0
var _caster: Node = null
var _left: bool = false  # left-handed mirroring (GameSettings)
var _expanded_row_y: float = 1300.0  # study row height (lower at match end)


## Mirrors an X across the canvas in left-handed mode.
func _mx(x: float) -> float:
	return 1080.0 - x if _left else x


func _ready() -> void:
	layer = 2
	_last_msec = Time.get_ticks_msec()

	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_caster = get_node_or_null(card_caster_path)
	if _caster == null:
		push_warning("CardHandHUD: card caster not found — hand inert.")
		return

	for i in 3:
		var card_res: CardResource = _caster.call(&"_card_for_slot", i + 1)
		var face: Control = _build_card_face(card_res)
		_root.add_child(face)
		_cards.append(face)
		_pos.append(_dock_pos(i))
		_pos_vel.append(Vector2.ZERO)
		_rot.append(_dock_rot(i))
		_rot_vel.append(0.0)
		_scale.append(1.0)
		_scale_vel.append(0.0)
		if card_res != null and card_res.is_reactive_only:
			_counter_slot = i
	_stack = get_node_or_null(^"/root/TheStack")
	# Conditional cards (DEFENSE/COUNTER) start hidden (shrunk away) until their cue pops them in.
	for hidden_i in [1, 2]:
		if hidden_i < _scale.size():
			_scale[hidden_i] = 0.0

	# NOTE: cards COMMIT ON PRESS now (no channel), so the card caster never emits
	# these charge signals — the CHARGING swell state is dormant for cards; a
	# pressed card goes DOCKED -> staged/hidden via _on_spell_staged. The connects
	# stay harmless (the same handlers serve a future charged card type).
	_caster.cast_charge_started.connect(_on_charge_started)
	_caster.cast_charge_canceled.connect(_on_charge_canceled)
	_caster.spell_staged.connect(_on_spell_staged)
	_caster.card_cast.connect(_on_card_cast)
	_caster.card_rejected.connect(_on_card_rejected)

	var mc: Node = get_node_or_null(match_controller_path)
	if mc != null:
		mc.round_ended.connect(_on_round_ended)
		mc.round_started.connect(_on_round_started)
		mc.match_ended.connect(_on_match_ended)

	# LEFT-HANDED MODE: the hand fans from the LEFT edge instead. Targets
	# recompute every frame, so the springs glide the cards across on toggle.
	var settings: Node = get_node_or_null(^"/root/GameSettings")
	if settings != null:
		settings.handedness_changed.connect(func(left: bool) -> void:
			_left = left
			# Re-base the sway: the camera's home X moved with the shoulder.
			_camera = null
			_root_offset = Vector2.ZERO
			_root_vel = Vector2.ZERO)
		_left = settings.left_handed


## NETPLAY (Phase 2c fix): re-point the hand at a different wizard's CardCasterComponent so
## the CLIENT's hand animates ITS OWN (Opponent) card casts + cooldowns. The HUD hard-binds
## the blue Player in _ready; MatchController calls this on the client (mirrors the cast
## button / health-bar retargets). Both wizards share the same 3-card test hand, so the
## already-built faces still match — only the signal source + per-slot cooldown query move.
func set_caster(caster: Node) -> void:
	if caster == null or caster == _caster:
		return
	if _caster != null:
		if _caster.cast_charge_started.is_connected(_on_charge_started):
			_caster.cast_charge_started.disconnect(_on_charge_started)
		if _caster.cast_charge_canceled.is_connected(_on_charge_canceled):
			_caster.cast_charge_canceled.disconnect(_on_charge_canceled)
		if _caster.spell_staged.is_connected(_on_spell_staged):
			_caster.spell_staged.disconnect(_on_spell_staged)
		if _caster.card_cast.is_connected(_on_card_cast):
			_caster.card_cast.disconnect(_on_card_cast)
		if _caster.card_rejected.is_connected(_on_card_rejected):
			_caster.card_rejected.disconnect(_on_card_rejected)
	_caster = caster
	_caster.cast_charge_started.connect(_on_charge_started)
	_caster.cast_charge_canceled.connect(_on_charge_canceled)
	_caster.spell_staged.connect(_on_spell_staged)
	_caster.card_cast.connect(_on_card_cast)
	_caster.card_rejected.connect(_on_card_rejected)


## One placeholder card face: dark panel, type-color header, name, cost
## pips, damage line, rules text (rules only shown staged/expanded).
func _build_card_face(card_res: CardResource) -> Control:
	var face := Panel.new()
	face.size = card_size
	face.pivot_offset = card_size * 0.5
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Long rules text must never spill past the card border (Creative
	# Director bug report — expanded view).
	face.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.13, 0.97)
	style.border_color = Color(0.8, 0.75, 0.6, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	face.add_theme_stylebox_override(&"panel", style)

	var type_idx: int = clampi(card_res.card_type, 0, 2) if card_res != null else 0
	var header := ColorRect.new()
	header.color = TYPE_COLORS[type_idx]
	header.position = Vector2(6, 6)
	header.size = Vector2(card_size.x - 12, 44)
	face.add_child(header)

	# IN-ROUND the card is ART + cost pips only (Creative Director: no one
	# reads rules text while dodging) — the art IS the message. Placeholder:
	# the fireball orb, tinted to the card's type.
	var art := TextureRect.new()
	art.texture = load(TYPE_ART[type_idx])
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.position = Vector2(30, 70)
	art.size = Vector2(card_size.x - 60, card_size.y - 120)
	face.add_child(art)
	_art_rects.append(art)

	# IN-ROUND "name": vague pixel hieroglyphs in the header strip — no real
	# UI besides the frame and the art (Creative Director).
	var runes := RuneStrip.new()
	runes.seed_value = (card_res.display_name if card_res != null else "x").hash()
	runes.position = Vector2(12, 10)
	runes.size = Vector2(card_size.x - 24, 36)
	runes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(runes)
	_rune_strips.append(runes)

	# POST-GAME (EXPANDED) text lives in TWO bordered containers UNDER the
	# art, MTG-style (Creative Director): container A = name + type/damage
	# line, container B = rules text. Hidden in-round.
	var panel_a := _make_info_panel(Vector2(10, 168), Vector2(card_size.x - 20, 58))
	face.add_child(panel_a)
	var name_label := Label.new()
	name_label.text = card_res.display_name if card_res != null else "—"
	name_label.position = Vector2(8, 2)
	name_label.size = Vector2(card_size.x - 36, 26)
	name_label.clip_text = true
	name_label.add_theme_font_size_override(&"font_size", 18)
	panel_a.add_child(name_label)
	var dmg_label := Label.new()
	var dmg: int = card_res.damage if card_res != null else 0
	dmg_label.text = ("%s  •  DMG %d" % [TYPE_NAMES[type_idx], dmg]) if dmg > 0 else ("%s  •  NO DMG" % TYPE_NAMES[type_idx])
	dmg_label.position = Vector2(8, 30)
	dmg_label.size = Vector2(card_size.x - 36, 22)
	dmg_label.clip_text = true
	dmg_label.add_theme_font_size_override(&"font_size", 14)
	dmg_label.add_theme_color_override(&"font_color", TYPE_COLORS[type_idx].lightened(0.35))
	panel_a.add_child(dmg_label)

	var panel_b := _make_info_panel(Vector2(10, 230), Vector2(card_size.x - 20, card_size.y - 240))
	face.add_child(panel_b)
	# ORDER MATTERS (screenshot-audit find): autowrap must be enabled BEFORE
	# size/text — with autowrap off, the label's minimum width snaps to the
	# full single-line text width and the wrap never engages.
	var desc := Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.clip_contents = true
	desc.add_theme_font_size_override(&"font_size", 12)
	desc.position = Vector2(8, 3)
	desc.size = Vector2(card_size.x - 36, card_size.y - 246)
	desc.text = card_res.description if card_res != null else ""
	panel_b.add_child(desc)
	_desc_labels.append(desc)
	_info_labels.append([panel_a, panel_b])

	return face


## A small bordered container (the MTG text-box look).
func _make_info_panel(pos: Vector2, panel_size: Vector2) -> Panel:
	var panel := Panel.new()
	panel.position = pos
	panel.size = panel_size
	panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.12, 0.1, 0.96)
	style.border_color = Color(0.78, 0.7, 0.5, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override(&"panel", style)
	return panel


# --- target poses per state ------------------------------------------

# NATURAL FAN (Creative Director): exposure grows toward the BOTTOM card —
# top tucked furthest behind the edge, bottom poking out most — with a
# progressive rotation like a loosely held hand. ~10% lower on screen.
# Sprint 20: pulled ~20% further into the screen (≈48 px = 0.2 × card width)
# so each card reveals more and is easier to tap (Creative Director).
const DOCK_X: Array[float] = [1054.0, 1026.0, 992.0]
const DOCK_ROT_DEG: Array[float] = [-50.0, -63.0, -78.0]

## VISUAL fan order: CARD INDEX -> fan slot (0 = top/tucked, 2 = bottom/most
## exposed). The card-caster SLOTS are unchanged (1 ATTACK / 2 DEFENSE / 3
## COUNTER, keys 8/9/0); only the on-screen order swaps so DEFENSE (index 1) is
## anchored at the BOTTOM and COUNTER (index 2) takes the middle (Phase 3, CD).
const VISUAL_ORDER: Array[int] = [0, 2, 1]


func _dock_pos(i: int) -> Vector2:
	var v: int = VISUAL_ORDER[i]
	return Vector2(_mx(DOCK_X[v]), 1010.0 + float(v) * 175.0)


func _dock_rot(i: int) -> float:
	var rot: float = deg_to_rad(DOCK_ROT_DEG[VISUAL_ORDER[i]])
	return -rot if _left else rot


func _target_for(i: int) -> Array:
	match _states[i]:
		CardState.CHARGING:
			# Higher and smaller than before (it covered too much court) —
			# still clearly larger than the docked hand.
			var rot: float = deg_to_rad(-10.0)
			return [Vector2(_mx(880.0), 600.0 + float(i) * 30.0), -rot if _left else rot, 1.12]
		CardState.EXPANDED:
			# Post-round study row: smaller, horizontal, BELOW the stats
			# section (match end pushes it lower still — podium + stats own
			# the upper half there).
			return [Vector2(200.0 + float(i) * 340.0, _expanded_row_y), 0.0, 1.0]
		_:
			# A conditional card that isn't available shrinks away (scale 0) until its cue pops it in.
			if not _expanded and not _available[i]:
				return [_dock_pos(i), _dock_rot(i), 0.0]
			return [_dock_pos(i), _dock_rot(i), 1.0]


func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_msec()
	var dt: float = clampf(float(now - _last_msec) / 1000.0, 0.0, 0.05)
	_last_msec = now
	if dt <= 0.0 or _cards.is_empty():
		return

	# Hand sway vs camera pan (momentum — the whole hand breathes).
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
		if _camera != null:
			_cam_base_x = _camera.global_position.x
	if _camera != null:
		# Clamped lean + clamped offset: the hand sways but never slides off
		# the screen edge (same fix as the health bar).
		var lean_x: float = clampf(
				-(_camera.global_position.x - _cam_base_x) * sway_per_meter,
				-20.0, 20.0)
		_root_vel += (Vector2(lean_x, 0) - _root_offset) * spring_stiffness * dt
		_root_vel *= maxf(0.0, 1.0 - spring_damping * dt)
		_root_offset += _root_vel * dt
		_root_offset = _root_offset.clamp(Vector2(-32, -32), Vector2(32, 32))
		_root.position = _root_offset

	# CONDITIONAL CARDS (Sprint 23 batch 3): refresh which cards are available this frame; a card
	# that just became available POPS in. Skipped during the expanded study spread (all show then).
	if not _expanded:
		_update_card_availability()

	for i in _cards.size():
		var target: Array = _target_for(i)
		_pos_vel[i] += (target[0] as Vector2 - _pos[i]) * spring_stiffness * dt
		_pos_vel[i] *= maxf(0.0, 1.0 - spring_damping * dt)
		_pos[i] += _pos_vel[i] * dt
		_rot_vel[i] += (target[1] as float - _rot[i]) * spring_stiffness * dt
		_rot_vel[i] *= maxf(0.0, 1.0 - spring_damping * dt)
		_rot[i] += _rot_vel[i] * dt
		_scale_vel[i] += (target[2] as float - _scale[i]) * spring_stiffness * dt
		_scale_vel[i] *= maxf(0.0, 1.0 - spring_damping * dt)
		_scale[i] += _scale_vel[i] * dt

		var face: Control = _cards[i]
		face.position = _pos[i] - card_size * 0.5
		face.rotation = _rot[i]
		face.scale = Vector2.ONE * _scale[i]
		face.z_index = 10 if _states[i] != CardState.DOCKED else VISUAL_ORDER[i]
		var expanded_now: bool = _states[i] == CardState.EXPANDED
		for info in _info_labels[i]:
			(info as Control).visible = expanded_now
		_rune_strips[i].visible = not expanded_now
		# MTG layout when studied: art sits in its own TOP slot above the
		# two text containers; in-round it fills the face.
		if expanded_now:
			_art_rects[i].position = Vector2(30, 48)
			_art_rects[i].size = Vector2(card_size.x - 60, 114)
			_art_rects[i].self_modulate.a = 1.0
		else:
			_art_rects[i].position = Vector2(30, 70)
			_art_rects[i].size = Vector2(card_size.x - 60, card_size.y - 120)
			_art_rects[i].self_modulate.a = 1.0

		# COUNTER GLOW: while an ENEMY spell sits on the stack and the
		# counter is castable, it pulses bright — "use me NOW".
		var counter_ready: bool = i == _counter_slot and not _expanded \
				and _stack != null and _stack.get(&"state") == 1 \
				and _caster != null and not bool(_caster.call(&"is_staging")) \
				and int(_caster.call(&"cooldown_ticks_remaining", i + 1)) == 0
		if counter_ready:
			var pulse: float = 0.5 + 0.5 * sin(float(now) / 1000.0 * 9.0)
			face.modulate = Color(0.75 + 0.5 * pulse, 0.95 + 0.3 * pulse, 1.3 + 0.6 * pulse)
		elif _states[i] == CardState.DOCKED and _caster != null \
				and int(_caster.call(&"cooldown_ticks_remaining", i + 1)) > 0:
			# COOLDOWN DIM: a cooling-down card sits gray in the hand.
			face.modulate = Color(0.5, 0.5, 0.55, 0.8)
		else:
			face.modulate = Color.WHITE
		# BLANKET GRADIENT (docked only): bottom card 40% transparent up to
		# the top card fully opaque (i 0 = top of the fan, i 2 = bottom).
		if _states[i] == CardState.DOCKED:
			face.modulate.a *= 1.0 - 0.2 * float(VISUAL_ORDER[i])


# --- state transitions (signal-driven) --------------------------------

func _slot_of(card: CardResource) -> int:
	for i in 3:
		if _caster.call(&"_card_for_slot", i + 1) == card:
			return i
	return -1


func _on_charge_started(card: SpellResource) -> void:
	var i: int = _slot_of(card)
	if i >= 0 and not _expanded:
		_states[i] = CardState.CHARGING
		# Anticipation: dip away before the swell.
		_pos_vel[i] += Vector2(180.0, 120.0)
		_scale_vel[i] -= 2.0


func _on_charge_canceled() -> void:
	_settle_all()


func _on_spell_staged(card: CardResource) -> void:
	# The card LEAVES THE HAND — it now lives on the StackDisplayHUD until
	# the stack resolves (card_cast brings it back to the dock).
	var i: int = _slot_of(card)
	if i >= 0:
		_cards[i].visible = false
		_states[i] = CardState.DOCKED if not _expanded else CardState.EXPANDED


func _on_card_cast(card: CardResource) -> void:
	var i: int = _slot_of(card)
	if i >= 0:
		_cards[i].visible = true
		# Re-enters the dock from the stack's direction with a little drop.
		_pos[i] = Vector2(_mx(900.0), 500.0)
		_pos_vel[i] = Vector2(300.0 * (-1.0 if _left else 1.0), 200.0)
	_settle_all()


func _on_card_rejected(card: CardResource) -> void:
	var i: int = _slot_of(card)
	if i >= 0:
		_pos_vel[i] += Vector2(-260.0, 0.0)  # refusal shake (spring decays it)
		_rot_vel[i] += 6.0


func _on_match_ended(_player_won: bool) -> void:
	# Lower than the round-break row so the PLAY AGAIN button clears beneath the
	# stats panel (match_flow_overlay places it at ~y1340).
	_expanded_row_y = 1660.0
	_on_round_ended(false, 0, 0, 0.0)


func _on_round_ended(_player_won: bool, _ps: int, _os: int, _break_s: float) -> void:
	_expanded = true
	for i in _states.size():
		_states[i] = CardState.EXPANDED
		_pos_vel[i] += Vector2(-300.0, 0.0)
		# A card stranded on the stack at the KO comes home for the study
		# phase (the round reset dropped the staged spell without firing).
		_cards[i].visible = true


func _on_round_started(_n: int) -> void:
	_expanded = false
	_expanded_row_y = 1300.0
	for i in _cards.size():
		_cards[i].visible = true
	_settle_all()


func _settle_all() -> void:
	if _expanded:
		return
	for i in _states.size():
		_states[i] = CardState.DOCKED


## Recomputes per-card availability and POPS in any card that just became usable (a springy scale
## kick from small). COUNTER (index 2) shows while a spell is on the stack; DEFENSE (index 1) while a
## hostile ball is incoming; ATTACK (index 0) is always in hand. Presentation only — the cards always
## WORK (keys 8/9/0 / hold-to-cast); this only gates whether they're shown in the fan.
func _update_card_availability() -> void:
	var avail: Array[bool] = [true, false, false]
	if _stack != null and int(_stack.get(&"state")) == 1:
		avail[2] = true  # a spell is on the stack — the counter is live
	# DEFENSE (index 1): pop EARLY — while a staged attack is within defense_predict_seconds of
	# resolving (read off the stack countdown, so there's time to tap on mobile) OR a ball is already
	# physically incoming (the fallback for the direct fireball, which never stages on the stack).
	var attack_imminent: bool = _stack != null and int(_stack.get(&"state")) == 1 \
			and _stack.has_method(&"remaining_seconds") \
			and float(_stack.call(&"remaining_seconds")) <= defense_predict_seconds
	var ball_incoming: bool = _caster != null and _caster.has_method(&"has_incoming_threat") \
			and bool(_caster.call(&"has_incoming_threat", defense_threat_range))
	# Only pop the shield in when it is actually CASTABLE — NOT while it is still cooling down (a
	# popped-in card you can't use yet is misleading; slot 2 = DEFENSE). Creative Director.
	var defense_off_cd: bool = _caster != null and _caster.has_method(&"cooldown_ticks_remaining") \
			and int(_caster.call(&"cooldown_ticks_remaining", 2)) == 0
	avail[1] = (attack_imminent or ball_incoming) and defense_off_cd
	for i in 3:
		if avail[i] and not _available[i] and _states[i] != CardState.EXPANDED:
			# POP IN at the dock slot, springing the scale up from small (overshoot = pop).
			_pos[i] = _dock_pos(i)
			_pos_vel[i] = Vector2.ZERO
			_scale[i] = 0.25
			_scale_vel[i] = 7.0
		_available[i] = avail[i]


# --- TOUCH: press-and-hold a card to channel/charge its spell --------
#
# Each fanned card is a hold target. Pressing one drives that slot's
# card_slot_N action (Input.action_press) — IDENTICAL to holding 8/9/0 on the
# keyboard — so attacks channel + stage on release, and instant defense/counter
# fire on the press edge, all through the unchanged deterministic pipeline.
#
# We hit-test in canvas space and track the owning finger by INDEX, releasing on
# that finger's lift no matter where it ended up: a charging card swells and
# slides up out from under the thumb, so a _gui_input release (which needs the
# pointer still over the card) would be dropped and the spell would charge
# forever. Global index tracking fixes that.

var _held_slot: int = -1
var _held_touch: int = -2   # -2 none, -1 mouse, >=0 finger index


## Topmost card whose (rotated/scaled) face contains [param pos], or -1.
func _card_hit(pos: Vector2) -> int:
	# Pick the card drawn ON TOP under the pointer: the highest VISUAL_ORDER
	# (most-exposed, bottom of the fan) wins when faces overlap.
	var best: int = -1
	var best_v: int = -1
	for i in _cards.size():
		if not _cards[i].visible:
			continue
		if not _expanded and not _available[i]:
			continue  # hidden conditional card — not tappable until it pops in
		var center: Vector2 = _pos[i] + _root_offset
		var scl: float = maxf(0.01, _scale[i])
		var local: Vector2 = (pos - center).rotated(-_rot[i]) / scl
		if absf(local.x) <= card_size.x * 0.5 and absf(local.y) <= card_size.y * 0.5:
			if VISUAL_ORDER[i] > best_v:
				best_v = VISUAL_ORDER[i]
				best = i
	return best


func _begin_card(slot: int, index: int) -> void:
	_held_slot = slot
	_held_touch = index
	var action: String = "card_slot_%d" % (slot + 1)
	if InputMap.has_action(action):
		Input.action_press(action)


func _end_card() -> void:
	if _held_slot >= 0:
		var action: String = "card_slot_%d" % (_held_slot + 1)
		if InputMap.has_action(action):
			Input.action_release(action)
	_held_slot = -1
	_held_touch = -2


func _input(event: InputEvent) -> void:
	# No card casting during the between-rounds study spread.
	if _expanded:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _held_touch == -2:
				var slot: int = _card_hit(event.position)
				if slot >= 0:
					_begin_card(slot, event.index)
					get_viewport().set_input_as_handled()
		elif event.index == _held_touch:
			_end_card()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _held_touch == -2:
				var slot: int = _card_hit(event.position)
				if slot >= 0:
					_begin_card(slot, -1)
					get_viewport().set_input_as_handled()
		elif _held_touch == -1:
			_end_card()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	# Release a held card if we lose focus / the tree pauses (ESC menu) mid-hold,
	# so the channel doesn't stick.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT \
			or what == NOTIFICATION_PAUSED:
		if _held_touch != -2:
			_end_card()
