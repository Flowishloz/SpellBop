## cast_button_hud.gd — The fireball CAST thumb button: same disc/ring format as
## the dash button, with a flame glyph and a charge ring instead of chevrons.
##
## WHY IT EXISTS (Creative Director): phones have no spacebar, so the base
## fireball had no mobile trigger. This button sits just LEFT of the dash button
## and drives the "cast_spell" action — press to begin the Mario-Kart charge,
## HOLD to bank power (the disc fills with a growing flame ring), RELEASE to
## throw. Identical to holding/releasing the spacebar, so the whole charge loop,
## aim system, and the slow-mo stack all behave exactly as on desktop.
##
## On the match-end screen "cast_spell" is also the rematch key, so this same
## button restarts the match on mobile (no code needed — MatchController already
## listens for the action).
extends TouchActionButton

## The player's SpellCasterComponent (charge-fraction source for the ring).
@export var caster_path: NodePath = NodePath("../../Player/SpellCasterComponent")

## SHIELD-RALLY CAST LOCK fade: alpha units/sec when a rally locks casting (~7 = ~0.14 s to fully fade out/in).
@export var cast_lock_fade_speed: float = 7.0

var _caster: Node

# Wall-clock eased alpha (1 = visible, 0 = faded away while a shield-rally cast lock is active).
var _lock_fade: float = 1.0


func _on_ready_extra() -> void:
	_caster = get_node_or_null(caster_path)
	if _caster == null or not _caster.has_method(&"charge_fraction"):
		push_warning("CastButtonHUD: SpellCasterComponent not found — ring inert.")
		_caster = null


## Re-point the charge ring at a different wizard's SpellCasterComponent. NETPLAY fix
## (Sprint 22): the button hard-codes the blue Player, but the CLIENT owns the red
## Opponent — MatchController calls this so each peer's button reads (and reacts to) ITS
## OWN wizard's charge, not the other player's.
func set_caster(caster: Node) -> void:
	if caster != null and caster.has_method(&"charge_fraction"):
		_caster = caster
		queue_redraw()


## SHIELD-RALLY CAST LOCK: fade the whole button away while a shield rally hold locks casting — the deck
## cards pop out at the same instant, and the base fireball is already gated in the sim, so this is the
## matching UI for "you can't cast right now." Springs back the moment the hold releases. Wall-clock eased
## (UI, immune to time_scale); presentation only — reads the caster's deterministic lock, never writes it.
func _process(delta: float) -> void:
	super._process(delta)  # base: press swell + label + redraw
	var locked: bool = _caster != null and _caster.has_method(&"is_cast_locked") \
			and bool(_caster.call(&"is_cast_locked"))
	_lock_fade = move_toward(_lock_fade, 0.0 if locked else 1.0, delta * maxf(0.1, cast_lock_fade_speed))
	modulate.a = _lock_fade


func _button_action() -> StringName:
	return &"cast_spell"


func _draw_progress(c: Vector2, r: float) -> void:
	# CHARGE RING: an arc that grows from 12 o'clock clockwise as the hold banks
	# power, shifting cool->hot (white -> orange -> gold) like a heating coil.
	# CHARGE RING SEGMENTED INTO THIRDS (Creative Director): one arc per charge
	# GAUGE, each lit in its gauge colour — yellow (1) / red (2) / blue (3) —
	# mirroring the wizard's charge particles. A reached gauge glows solid; the
	# gauge currently filling pulses; unreached gauges are a faint track.
	if _caster == null:
		return
	var level: int = _caster.charge_level()
	var charging: bool = _caster.charge_fraction() > 0.001
	if not charging and level <= 0:
		return
	var seg: float = TAU / 3.0
	var gap: float = 0.18  # radians of empty between thirds
	var pulse: float = 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 1000.0 * 12.0)
	for s in 3:
		var a0: float = -PI / 2.0 + float(s) * seg + gap * 0.5
		var a1: float = -PI / 2.0 + float(s + 1) * seg - gap * 0.5
		var col: Color = _gauge_color(s)
		if level >= s + 1:                       # gauge reached → solid glow
			col.a = 1.0
			draw_arc(c, r - 5.0, a0, a1, 24, col, 8.0, true)
		elif charging and level == s:            # the gauge currently filling
			col.a = 0.3 + 0.5 * pulse
			draw_arc(c, r - 5.0, a0, a1, 24, col, 8.0, true)
		else:                                    # unreached track
			draw_arc(c, r - 5.0, a0, a1, 24, Color(1, 1, 1, 0.12), 5.0, true)


## A soft halo behind the button whose colour matches the CURRENT charge gauge
## (yellow/red/blue) and whose intensity grows as the charge banks. Idle = no
## glow. (Concentric translucent circles, largest+faintest first so the inner
## brighter rings layer on top = a fading aura.)
func _draw_glow(c: Vector2, r: float) -> void:
	if _caster == null:
		return
	var frac: float = _caster.charge_fraction()
	var level: int = _caster.charge_level()
	if frac <= 0.001 and level <= 0:
		return
	var col: Color = Color(1.0, 0.85, 0.45) if level <= 0 else _gauge_color(level - 1)
	var intensity: float = clampf(0.35 + 0.65 * frac, 0.0, 1.0)
	var layers: int = 6
	for i in layers:
		var t: float = 1.0 - float(i) / float(layers)   # 1 = outermost ring
		var gr: float = r * (1.0 + 0.95 * t)
		var gc: Color = col
		gc.a = intensity * (0.05 + 0.06 * (1.0 - t))
		draw_circle(c, gr, gc)


## The charge gauge colours (index 0-2 = gauge 1-3) — yellow / red / blue.
func _gauge_color(i: int) -> Color:
	match i:
		0: return Color(1.0, 0.92, 0.2)
		1: return Color(1.0, 0.3, 0.15)
		_: return Color(0.3, 0.6, 1.0)


func _draw_icon(c: Vector2, r: float) -> void:
	# Stylized flame: a teardrop body with an inner core. Tints toward the
	# CURRENT charge gauge's colour so the button reads its level at a glance.
	var level: int = _caster.charge_level() if _caster != null else 0
	var frac: float = _caster.charge_fraction() if _caster != null else 0.0
	var s: float = r * 0.5
	var base_body := Color(1.0, 0.5, 0.18, 0.95).lerp(Color(1.0, 0.85, 0.35, 1.0), frac)
	var body: Color = base_body if level <= 0 else _gauge_color(level - 1)
	body.a = 0.95
	var flame := PackedVector2Array([
		c + Vector2(0.0, -s * 1.15),          # tip
		c + Vector2(s * 0.72, s * 0.15),      # right shoulder
		c + Vector2(s * 0.42, s * 0.85),      # right base
		c + Vector2(-s * 0.42, s * 0.85),     # left base
		c + Vector2(-s * 0.72, s * 0.15),     # left shoulder
	])
	draw_colored_polygon(flame, body)
	# Inner core (hotter), a smaller offset flame.
	var core_s: float = s * 0.5
	var core := PackedVector2Array([
		c + Vector2(0.0, -core_s * 0.6),
		c + Vector2(core_s * 0.6, s * 0.2),
		c + Vector2(0.0, s * 0.7),
		c + Vector2(-core_s * 0.6, s * 0.2),
	])
	draw_colored_polygon(core, Color(1.0, 0.95, 0.7, 0.9))
