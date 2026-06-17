## match_controller.gd — Arena orchestration: the Stack, feedback, and ROUNDS.
##
## ROLE: the decoupling seam between gameplay components and global systems.
## Components stay pure (casters emit signals); THIS script decides what they
## mean at match level:
##   - a STAGED attack card opens The Stack's countdown window (the spell sits
##     "on the stack" until the countdown releases it — Creative Director);
##   - presentation feedback routes to the camera rig's trauma shake
##     (charge rumble, cast bursts, barrier capture build-up, damage, etc.);
##   - ROUND FLOW (best of 3): KO ends the round, a 15 s post-round phase
##     shows the expanded hand, first to 2 rounds takes the match, the
##     victory screen offers a rematch.
##
## TIMING NOTE (Sprint 22 Sub-phase 3): round flow is now DETERMINISTIC — the
## RoundFlowResolver (a network_sync node) owns KO detection, scores, the death/break
## countdown, and the in-tick round reset, so transitions land on agreed sim ticks on
## both peers. This file MIRRORS that state for the UI and runs the death/break
## CINEMATICS (slow-mo, dolly zoom, banners, overlays) off the resolver's phase-change
## signals, rollback-guarded — presentation only.
class_name MatchController
extends Node3D

enum MatchState { ROUND_ACTIVE, POST_ROUND, MATCH_OVER }

## Round flow announcements (HUD/overlay hooks — listeners read only).
signal round_started(round_number: int)
signal round_ended(player_won_round: bool, player_score: int, opponent_score: int, break_seconds: float)
signal match_ended(player_won_match: bool)

## The stack just resolved and a winner was decided (last responder). UI hook for
## the Phase 3 stack-winner indicator. player_won = the LOCAL player won it.
signal stack_winner_decided(player_won: bool)

## A KO landed and the death sequence began (Sprint 20): slow-mo + death cam + the
## bigger explosion. is_match_end is true on the final blow (vs a round KO);
## player_won = the LOCAL player won the round. MatchFlowOverlay shows the
## VICTORY/DEFEAT verdict heading off this, high on screen, during the death beat.
signal knockout_began(is_match_end: bool, player_won: bool)

## The arena camera (a PunchOutCameraRig) that receives shake feedback.
@export var camera_path: NodePath = NodePath("Camera3D")

## The LOCAL player's controller node. Only this wizard's charge-up rumbles
## the camera — the opponent charging across the court shouldn't shake the
## viewer's hands. Casts and hits shake for everyone (impact is impact).
@export var player_path: NodePath = NodePath("Player")

## The AI opponent's controller node.
@export var opponent_path: NodePath = NodePath("Opponent")

## Where the Projectiles container lives (cleared between rounds).
@export var projectiles_path: NodePath = NodePath("Projectiles")

## Rounds needed to take the match (2 = best of 3).
@export var rounds_to_win: int = 2

## Real seconds of the post-round break (expanded-hand study phase).
@export var post_round_seconds: float = 6.0

## ROUND INTRO (Sprint 23 batch 3, Creative Director): a brief "ready, GO" beat at each round start —
## the ROUND-N title pops in the top section and FLIES OFF the screen, and the round becomes playable
## (the wizards unfreeze) only as it leaves. OFFLINE only: the freeze is the local tick-driver park, a
## no-op in netplay (SyncManager drives the ticks), so an online round stays live under the title.
## Tests collapse it to 0 (no freeze). The overlay reads this for the title's matching fly-off timing.
@export var round_intro_seconds: float = 1.0

## Spawn baselines (sim units) used for the round reset.
@export var player_spawn_y: float = 880.0
@export var opponent_spawn_y: float = -880.0

## Camera trauma per event (0..1; displayed shake is trauma squared).
@export var cast_trauma: float = 0.15
@export var card_cast_trauma: float = 0.3
@export var player_hit_trauma: float = 0.5
@export var opponent_hit_trauma: float = 0.25
## LAUNCH KICK (Sprint 23 batch 2, Creative Director): an extra sharp camera trauma kick when the LOCAL
## player FIRES a fireball — on top of the per-cast trauma + the FOV punch — so the throw has recoil.
## Paired with a muzzle BURST at the spawn point (see _on_spell_cast).
@export var launch_kick_trauma: float = 0.22
## Camera trauma SLAM when a shield flings a captured ball back. Sprint 20 round-4:
## raised 0.55 -> 0.9 to exaggerate the reflect release (Creative Director).
@export var capture_release_trauma: float = 0.9

## PHASE 5 (Creative Director): amplify the FIRING impact — every projectile spawn
## adds 20% more camera trauma than its base cast/card value.
@export var fire_shake_multiplier: float = 1.2

## Sustained rumble per fireball charge level (index = level 0-3). Escalates
## hard so each banked gauge visibly grips the screen more (Creative Director).
@export var charge_rumble_levels: Array[float] = [0.06, 0.22, 0.4, 0.62]

## Extra one-shot trauma KICK the instant a new gauge banks, scaled by the gauge
## number (gauge 1 = 1x, 2 = 2x, 3 = 3x of this) — a sharp "pop" per fill.
@export var charge_pop_trauma: float = 0.1

## STACK WINNER REWARD: the player who placed the NEWEST spell on the stack (last
## responder, always) gets this launch-speed multiplier on their NEXT projectile.
@export var stack_winner_speed_multiplier: float = 1.5

## HEALING EMERALD (Phase 1, Creative Director): a glowing emerald spawns near the
## arena centre every emerald_min..max seconds; striking it with a projectile
## grants the thrower a life back. Assign scenes/emerald.tscn.
@export var emerald_scene: PackedScene
@export var emerald_min_interval_seconds: float = 25.0
@export var emerald_max_interval_seconds: float = 40.0
## Seed for the deterministic spawn-cadence + position LCG (mixed with the round
## number so each round differs but replays identically).
@export var emerald_seed: int = 24301

## HEALING EMERALD CAP (Sprint 20, Creative Director): at most this many emeralds
## spawn across an entire MATCH (not per round). Resets only on a fresh match
## (request_rematch). Exactly one is ever on the field at a time.
@export var emerald_max_per_match: int = 2

@export_group("Death Sequence")
## DEATH SEQUENCE (Sprint 20, Creative Director): a KO triggers a slow-mo death
## beat BEFORE the result overlay. The world dilates to death_time_scale, the
## camera zooms onto and tracks the eliminated wizard, a bigger explosion + a
## screen-space ripple fire from the point of contact, and the post-round /
## post-game overlay waits death_sequence_seconds while it all plays.
@export_range(0.05, 1.0) var death_time_scale: float = 0.3
@export var death_sequence_seconds: float = 2.5
## KNOCKOUT DOLLY TIGHTNESS by outcome (Creative Director): the death-cam dolly's
## END distance scale — a TIGHTER push-in celebrating a WIN (0.65), a gentler one
## on a LOSS (0.80). Lower = the dolly ends closer to the eliminated wizard.
@export_range(0.1, 1.5) var death_zoom_scale_win: float = 0.65
@export_range(0.1, 1.5) var death_zoom_scale_lose: float = 0.8
## Peak UV displacement of the death screen-ripple (retro_lens ripple_strength).
@export var death_ripple_strength: float = 0.05
## SCALED seconds for the ripple ring to fully expand (slows with the dilation).
@export var death_ripple_seconds: float = 0.7

@export_group("Shield & Emerald FX")
## SHIELD REFLECT DRAMA (Sprint 20 round-4, Creative Director): when a barrier
## CATCHES a fireball it becomes a slow-mo ANTICIPATION beat — the world dilates to
## this scale for the capture-hold so the Window-of-Affect reflect is clearly
## visible, with a screen ripple and a heavy release slam. 1.0 disables the slow-mo.
@export_range(0.05, 1.0) var shield_capture_time_scale: float = 0.4
## VARIABLE SHIELD REFLECT (Sprint 23, Creative Director): the barrier emits a reflect INTENSITY
## (0..1 = WOA blended with incoming speed) on capture_started; these MIN/MAX pairs scale the whole
## beat by it — a low-intensity block (slow ball / loose timing) gets a small + FAST ripple, a mild
## slow-mo + a light slam; a high-intensity one (fast ball / last-moment block) the full drama.
## shield_capture_time_scale (above) is the DEEPEST (high-intensity) slow-mo; this is the mildest:
@export_range(0.05, 1.0) var shield_capture_time_scale_mild: float = 0.62
## Shield displacement-wave peak UV displacement (SIZE): min at low intensity, max at high.
@export var shield_ripple_strength_min: float = 0.03
@export var shield_ripple_strength_max: float = 0.055
## Shield displacement-wave expansion time in seconds (SPEED): short/fast at low intensity, long at high.
@export var shield_ripple_seconds_min: float = 0.32
@export var shield_ripple_seconds_max: float = 0.7
## Release SLAM camera trauma: min at low intensity, capture_release_trauma (above) at high.
@export var capture_release_trauma_min: float = 0.5
## The anticipation rumble is scaled by this at low intensity, up to 1.0 at high intensity.
@export var shield_rumble_min_scale: float = 0.6
## Peak UV displacement of the EMERALD screen ripple (unchanged — not part of the variable shield set).
@export var emerald_ripple_strength: float = 0.04
## HITSTOP (Sprint 23, Creative Director): a wizard taking a hit triggers a brief presentation freeze
## (the impact "crunch", the_stack.hitstop), with the duration scaled by the damage — a 1-damage
## graze gets ~hitstop_min_ms, a hitstop_ref_damage-point hit gets hitstop_max_ms.
@export var hitstop_min_ms: int = 45
@export var hitstop_max_ms: int = 110
@export var hitstop_ref_damage: float = 3.0
## HARD KO HITSTOP (Sprint 23 batch 2, Creative Director): a sharp FREEZE that lands BEFORE the death
## slow-mo on a knockout — the kill connects with a crunch, THEN the world eases into the slow-mo death
## beat (the_stack.hitstop's then-hold transition). Longer than a regular hit's freeze; fires only when
## the death slow-mo is enabled (death_time_scale < 1.0).
@export var ko_hitstop_ms: int = 130
## PLAYER-DAMAGE SLOW-MO (Sprint 23 batch 3, Creative Director): a NON-LETHAL hit eases the hitstop
## crunch into a real-time slow-mo so the impact + its particles play out in slow motion. _scale = the
## dilation depth, _seconds = how long it HOLDS in REAL time before ramping back. (A lethal hit uses the
## death sequence's own slow-mo instead.) Stack-window slow-mo was REMOVED — this + shield reflect +
## death are the only slow-mo sources now.
@export_range(0.05, 1.0) var damage_slow_scale: float = 0.35
@export var damage_slow_seconds: float = 2.0

var match_state: MatchState = MatchState.ROUND_ACTIVE

## NETPLAY (Sprint 21): true when the rollback SyncManager (LAN/online) drives the
## two wizards instead of the local tick drivers. Set in _ready() from
## NetworkManager. Disables the (not-yet-rollback-routed) emerald spawner and the
## local-driver park/resume seam.
var _netplay: bool = false
var round_number: int = 1
var player_score: int = 0
var opponent_score: int = 0

var _stack: Node = null
var _camera: PunchOutCameraRig = null
var _player: Node = null
var _opponent: Node = null
var _projectiles: Node = null

# THE STACK (Sprint 22 Phase 2): resolution + the winner reward now live on the
# deterministic StackResolver (a network_sync node) so they land on the SAME sim tick
# on both peers. This controller only OPENS the presentation window (TheStack dilation)
# and reacts to the resolver's `resolved` signal for presentation cleanup. The casters
# arm the resolver themselves when they stage.
var _resolver: StackResolver = null

# ROUND FLOW (Sprint 22 Sub-phase 3): KO detection, scores, the death/break
# countdown, and the in-tick round reset now live on the deterministic
# RoundFlowResolver (a network_sync node) so they land on the SAME sim tick on both
# peers. This controller MIRRORS its scores/round/phase for the UI read surface
# (player_score / opponent_score / round_number / match_state above) and runs the
# death/break CINEMATICS off its phase-change signals, rollback-guarded — the
# resolver is the sim authority, this file is presentation.
var _roundflow: RoundFlowResolver = null

# AIM ARROW (Mobile-MP B2b): a glowing ground arrow at the LOCAL wizard's feet
# showing the firing angle while it charges / stages. Pure presentation; it retargets
# to the local wizard each frame via _local_wizard() (authority-based, so it follows
# the client's OWN wizard with no hardwiring — sidesteps the client-perspective rule).
const _AIM_ARROW_SCRIPT := preload("res://scripts/visual/aim_arrow.gd")
var _aim_arrow = null

# stack_winner_speed_multiplier cached to fixed-point (1.5 -> 98304).
var _stack_winner_boost_fp: int = 98304

# HEALING EMERALD (spawn-rollback Phase 3): the spawn cadence (LCG + countdown +
# per-match cap) now lives on the RoundFlowResolver as ROLLED-BACK sim state, so the
# spawn lands on the same tick on both peers. This controller only provides the spawn
# HOOK (_spawn_emerald_synced) + the claimed->ripple presentation.

# DEATH SEQUENCE state (Sprint 20). The retro-lens material drives the screen
# ripple; _ripple_* tracks the active shockwave; _in_death_sequence guards the
# parked POST_ROUND/MATCH_OVER flow so the next round / a rematch can't start
# until the death beat finishes.
var _lens_mat: ShaderMaterial = null
var _ripple_active: bool = false
var _ripple_progress: float = 0.0
var _ripple_seconds: float = 0.7   # per-ripple expansion duration (set by _trigger_ripple)
# Reflect intensity (0..1) of the CURRENT shield capture (from capture_started) — scales the
# rumble through the hold and the release slam; see _on_capture_started / _on_capture_released.
var _capture_intensity: float = 1.0
var _in_death_sequence: bool = false
# True while a shield capture-hold is dilating time (so capture_released knows to
# resume). Guards against resuming when the slow-mo wasn't ours to begin with.
var _shield_slowmo_active: bool = false

# Tracks the window's open state so the tape-slow cue plays only on the
# NORMAL -> WINDOW transition, not on every counter-slap refresh.
var _window_open_flag: bool = false

# ROUND INTRO (Sprint 23 batch 3): wall-clock deadline (msec) of the current round-intro freeze
# (0 = none). While set, the local sim is parked; _process unparks it as the title flies off.
var _round_intro_until_msec: int = 0

# Last fireball charge gauge seen, so the per-gauge trauma pop fires only on the
# RISING edge (a draining charge re-emits falling levels and must not burst).
var _prev_charge_level: int = 0

# MATCH STATS (presentation bookkeeping for the results screens — read via
# get_stats()). Throws = damaging projectiles the player launched; hits =
# damage events landed on the opponent.
var _stat_throws: int = 0
var _stat_hits: int = 0
var _stat_damage_dealt: int = 0
var _stat_damage_taken: int = 0


func _ready() -> void:
	# Defensive autoload lookup (headless harnesses may strip autoloads).
	_stack = get_node_or_null(^"/root/TheStack")
	if _stack == null:
		push_warning("MatchController: TheStack autoload not found — casts will not slow time.")

	_camera = get_node_or_null(camera_path) as PunchOutCameraRig
	_player = get_node_or_null(player_path)
	_opponent = get_node_or_null(opponent_path)
	_projectiles = get_node_or_null(projectiles_path)
	# RELIABLE SHIELD-WAVE WIRING (Sprint 23): wire each barrier's capture presentation on spawn
	# (child_entered_tree fires for EVERY spawn incl. rollback re-spawns), NOT via the caster's
	# spell_cast signal — that is rollback-suppressed, so a barrier deployed on a rolled-back tick
	# was never wired and its block produced no displacement wave. See _on_projectile_entered.
	if _projectiles != null:
		_projectiles.child_entered_tree.connect(_on_projectile_entered)
	_stack_winner_boost_fp = SGFixed.from_float(maxf(1.0, stack_winner_speed_multiplier))

	# Death screen-ripple driver: grab the retro-lens shader material and clear any
	# stale ripple so the pass renders normally until a KO arms it.
	var lens: Node = get_node_or_null(^"RetroPostFX/LensRect")
	if lens != null and lens.get(&"material") is ShaderMaterial:
		_lens_mat = lens.get(&"material") as ShaderMaterial
		_lens_mat.set_shader_parameter(&"ripple_progress", -1.0)

	# Wire EVERY caster in the arena (player and AI alike). owned=false so
	# casters inside instanced scenes (player.tscn) are found.
	for caster in find_children("*", "SpellCasterComponent", true, false):
		caster.spell_cast.connect(_on_spell_cast)
	var card_casters: Array[Node] = find_children("*", "CardCasterComponent", true, false)
	for caster in card_casters:
		caster.spell_cast.connect(_on_spell_cast)
		# STAGING opens the presentation window (slow-mo + telegraph); the actual
		# release + the winner reward are the StackResolver's deterministic tick.
		caster.spell_staged.connect(_on_spell_staged)

	# THE STACK SIM AUTHORITY (Sprint 22 Phase 2): hand the resolver its stable scene
	# refs and listen for its resolution beat (presentation cleanup, rollback-guarded).
	_resolver = get_node_or_null(^"StackResolver") as StackResolver
	if _resolver != null:
		_resolver.setup(card_casters, _player, _opponent, _stack_winner_boost_fp)
		_resolver.resolved.connect(_on_resolver_resolved)

	# ROUND FLOW SIM AUTHORITY (Sprint 22 Sub-phase 3): hand the round resolver its
	# stable refs (both wizards + their HealthComponents, the Projectiles container, the
	# stack resolver it cancels on a KO) + the round tuning, and listen for its
	# deterministic phase-change beats to drive the death/break CINEMATICS (mirrors the
	# StackResolver wiring above).
	_roundflow = get_node_or_null(^"RoundFlowResolver") as RoundFlowResolver
	if _roundflow != null:
		var p_health: Node = _player.get_node_or_null(^"Health") if _player != null else null
		var o_health: Node = _opponent.get_node_or_null(^"Health") if _opponent != null else null
		_roundflow.setup(_player, _opponent, p_health, o_health, _projectiles, _resolver,
				death_sequence_seconds, post_round_seconds, rounds_to_win,
				SGFixed.from_float(player_spawn_y), SGFixed.from_float(opponent_spawn_y))
		_roundflow.ko_began.connect(_on_resolver_ko)
		_roundflow.break_began.connect(_on_resolver_break)
		_roundflow.match_concluded.connect(_on_resolver_match_concluded)
		_roundflow.round_reset.connect(_on_resolver_round_reset)
		# Emerald cadence (Phase 3): hand the resolver the tick-converted interval + cap +
		# seed and the SyncManager.spawn HOOK (so the resolver stays SyncManager-free).
		var em_min: int = maxi(1, int(emerald_min_interval_seconds * 60.0))
		var em_span: int = maxi(1, int((emerald_max_interval_seconds - emerald_min_interval_seconds) * 60.0))
		_roundflow.setup_emerald(emerald_scene != null, em_min, em_span, emerald_max_per_match,
				emerald_seed, _spawn_emerald_synced)

	# Damage feedback: every wizard's hits shake the camera (presentation + stats).
	# ROUND FLOW (KO -> round end) is the RoundFlowResolver's job now — it POLLS HP on
	# its own tick. The knocked_out SIGNAL re-fires on a rollback re-sim and would
	# double-count the score, so it is NOT used for round flow (see round_flow_resolver.gd).
	for health in find_children("*", "HealthComponent", true, false):
		var is_player_side: bool = _is_under_player(health)
		var trauma: float = player_hit_trauma if is_player_side else opponent_hit_trauma
		health.damaged.connect(_on_wizard_damaged.bind(health, trauma, is_player_side))

	# Charge-up rumble + throw stat: LOCAL player's casters only (see player_path doc).
	# Defaults to the blue Player (offline + the netplay HOST); the CLIENT retargets this
	# to its red Opponent in _enter_netplay.
	_wire_local_charge_feedback(_player, true)

	_enter_netplay()
	_apply_equipped_skin()
	round_started.emit(round_number)
	_begin_round_intro()
	_warm_up_render_pipelines()
	_build_arena_borders()
	_aim_arrow = _AIM_ARROW_SCRIPT.new()
	add_child(_aim_arrow)


## COSMETICS (equip -> match): dress the LOCAL human's wizard in the skin EQUIPPED in the Cosmetics
## screen (GameSettings.equipped_skin -> SkinCatalog.palette_for -> WizardAnimator.set_skin). The match
## scene hardcodes the blue/red skins on player.tscn/opponent.tscn; this overrides the local one at
## match start. PRESENTATION ONLY — set_skin swaps the visual palette/texture on the WizardAnimator (a
## plain Node, NOT in network_sync), so the deterministic sim is untouched (the sweep stays bit-identical).
## Offline that's the blue Player; in netplay it's whichever wizard THIS peer owns (host=blue/client=red),
## so each peer wears its OWN equipped skin (remote peers' skins aren't synced — a future enhancement).
## No-ops safely when the GameSettings autoload is absent (headless test harnesses may strip it).
func _apply_equipped_skin() -> void:
	var gs: Node = get_node_or_null(^"/root/GameSettings")
	if gs == null:
		return
	# Local player's wizard wears the EQUIPPED skin (offline = blue Player; netplay = this peer's wizard).
	var wiz: Node = _local_wizard()
	if wiz == null:
		wiz = _player   # offline / pre-authority: the human drives the blue Player
	_apply_skin_to(wiz, gs.get(&"equipped_skin"))
	# DEBUG (OFFLINE ONLY): the Cosmetics "Equip skin for opponent" toggle can force a skin onto the AI
	# opponent. Skipped in netplay — there the opponent is a real remote peer with its own wizard/skin.
	if not _netplay:
		_apply_skin_to(_opponent, gs.get(&"opponent_skin"))


## Swap a wizard's visual skin from a (possibly empty/null) skin id. PRESENTATION ONLY — set_skin touches
## the non-sim WizardAnimator, never saved/rollback state. No-ops on a null wizard, a null/empty id, or an
## unknown id (SkinCatalog.palette_for returns null → the wizard keeps its scene-default skin).
func _apply_skin_to(wiz: Node, skin_id: Variant) -> void:
	if wiz == null or skin_id == null:
		return
	var palette: SkinPalette = SkinCatalog.palette_for(skin_id)
	if palette == null:
		return
	var animator: Node = wiz.get_node_or_null(^"WizardAnimator")
	if animator != null and animator.has_method(&"set_skin"):
		animator.set_skin(palette)


## LAG-SPIKE FIX (slow-mo exit hitch): the first stack resolution used to
## instantiate projectile scenes (meshes, lights, particle materials) whose
## shaders/pipelines compile ON FIRST DRAW — one big hitch exactly as time
## snapped back to 1.0. Warm everything during round start instead: draw
## each scene once just UNDER the floor (rendered, occluded), plus one of
## each burst, then free them.
func _warm_up_render_pipelines() -> void:
	var parked: Array[Node] = []
	for path in [
		"res://scenes/fireball.tscn", "res://scenes/spark_bolt.tscn",
		"res://scenes/ice_wave.tscn", "res://scenes/barrier.tscn",
	]:
		var packed: PackedScene = load(path)
		if packed == null:
			continue
		var inst: Node = packed.instantiate()
		inst.set(&"local_tick_driver_enabled", false)
		add_child(inst)
		# NETPLAY DESYNC FIX (round-2 freeze): these are PRESENTATION-only shader-warm
		# instances, but each scene ROOT is an SG physics body — its _ready() registers it in
		# the deterministic SG space (barrier.tscn on layer WALLS, the projectiles likewise),
		# and we only move the VISUAL Node3D under the floor, so the COLLIDER stays at sim
		# (0,0) = arena CENTRE. A gameplay fireball crossing the centre then BOUNCES off the
		# warm-up barrier — and because these are freed on a WALL-CLOCK timer (below), not a
		# synced tick, their presence at a given sim tick differs between peers under rollback:
		# one peer reflects the ball, the other doesn't -> "Fatal state mismatch" -> the
		# round-2 freeze. Make every warm-up body collision-INERT (no layer, no mask) so it
		# renders/warms pipelines without ever touching the rollback sim.
		if "collision_layer" in inst:
			inst.collision_layer = 0
			inst.collision_mask = 0
			if inst.has_method(&"sync_to_physics_engine"):
				inst.sync_to_physics_engine()
		for child in inst.get_children():
			if child is Node3D:
				(child as Node3D).position = Vector3(0, -0.9, 6)
		# Hide any glow LIGHTS on the warm-up instance (Sprint 23 batch 3 follow-up): the meshes warm
		# their shaders occluded under the floor, but a fireball/spark OmniLight would still cast a glow
		# ABOVE the floor at centre-court — visible now that the round-intro beat holds a static frame.
		for light in inst.find_children("*", "Light3D", true, false):
			(light as Node3D).visible = false
		parked.append(inst)
	BurstFX.spawn(self, Vector3(0, -0.9, 6), Vector3.UP, Color(1, 0.55, 0.2, 0.9), 4, 1.0)
	BurstFX.spawn(self, Vector3(0, -0.9, 6), Vector3.UP, Color(0.45, 0.9, 0.6, 0.9), 4, 1.0)
	BurstFX.spawn(self, Vector3(0, -0.9, 6), Vector3.UP, Color(0.55, 0.8, 1.0, 0.9), 4, 1.0)
	# NOTE: the wall-pulse warm-up was REMOVED (Sprint 23 batch 3 follow-up) — spawn_wall_pulse clamps
	# Y up to 0.6 (ABOVE the floor), so at centre-court it "popped in" during the static round-intro
	# beat. It uses a cheap StandardMaterial3D (no heavy shader), so the first real side-wall bounce
	# compiles it with no perceptible hitch.
	var timer: SceneTreeTimer = get_tree().create_timer(0.4)
	timer.timeout.connect(func() -> void:
		for inst in parked:
			if is_instance_valid(inst):
				inst.queue_free())


## GLOWING ARENA BORDERS (Phase 4, Creative Director): a neon perimeter framing
## the floor. Script-built emissive strips just above the floor plane (the floor
## is 9.6 x 21, centred at the origin).
func _build_arena_borders() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.95, 1.0)
	mat.emission_energy_multiplier = 2.4
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var half_x: float = 4.75
	var half_z: float = 10.4
	var thick: float = 0.12
	var tall: float = 0.16
	var y: float = 0.08
	var edges: Array = [
		[Vector3(thick, tall, half_z * 2.0), Vector3(-half_x, y, 0.0)],   # left
		[Vector3(thick, tall, half_z * 2.0), Vector3(half_x, y, 0.0)],    # right
		[Vector3(half_x * 2.0, tall, thick), Vector3(0.0, y, half_z)],    # near
		[Vector3(half_x * 2.0, tall, thick), Vector3(0.0, y, -half_z)],   # far
	]
	for edge in edges:
		var box := BoxMesh.new()
		box.size = edge[0]
		box.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.position = edge[1]
		add_child(mi)


func _process(delta: float) -> void:
	_update_death_ripple(delta)
	_update_aim_arrow()
	# PRESENTATION MIRROR (Sub-phase 3): keep the UI read-surface fields in lockstep
	# with the RoundFlowResolver's authoritative (rolled-back) sim state every frame,
	# so a mispredicted-then-rolled-back KO can never leave the scoreboard / state
	# drifted (the signal handlers below are rollback-guarded; this passive sync is not).
	_sync_mirror()
	# ROUND INTRO (Sprint 23 batch 3): unfreeze the local sim once the round-intro title has flown off.
	if _round_intro_until_msec > 0 and Time.get_ticks_msec() >= _round_intro_until_msec:
		_round_intro_until_msec = 0
		_set_sim_running(true)
	# Desktop convenience: SPACE restarts a finished match (the on-screen PLAY AGAIN
	# button is the primary trigger). request_rematch() routes correctly per mode —
	# offline it resets directly, in netplay it latches a synced play-again request.
	if match_state == MatchState.MATCH_OVER:
		if Input.is_action_just_pressed("cast_spell"):
			request_rematch()


## Advances the screen-space death ripple on SCALED time (so the shockwave expands
## slowly during the death slow-mo, like the rest of the 3D), then clears it.
func _update_death_ripple(delta: float) -> void:
	if not _ripple_active or _lens_mat == null:
		return
	_ripple_progress += delta / maxf(0.0001, _ripple_seconds)
	_lens_mat.set_shader_parameter(&"ripple_progress", _ripple_progress)
	if _ripple_progress >= 1.0:
		_ripple_active = false
		_lens_mat.set_shader_parameter(&"ripple_progress", -1.0)


## Restart the match from a fresh scoreboard (the PLAY AGAIN button + the SPACE
## shortcut both route here). No-op unless the match is actually over.
func request_rematch() -> void:
	if match_state != MatchState.MATCH_OVER:
		return
	if _netplay:
		# Online rematch is DETERMINISTIC: latch a play-again on the LOCAL wizard's synced
		# input; the RoundFlowResolver runs reset_match() on the agreed tick on BOTH peers
		# (an off-tick / RPC reset would land on different ticks and desync). The result
		# screen then hides via the resolver's round_reset signal, exactly like offline.
		var lw: Node = _local_wizard()
		if lw != null and lw.has_method(&"latch_rematch"):
			lw.latch_rematch()
		return
	# OFFLINE: reset the sim authority directly (no rollback to coordinate). reset_match()
	# emits round_reset(1) -> _on_resolver_round_reset does ALL the presentation (mirror,
	# unpark, stats + emerald-budget reset, ROUND 1 banner).
	if _roundflow != null:
		_roundflow.reset_match()


# =====================================================================
# Healing emerald (Phase 1)
# =====================================================================

## SPAWN HOOK — called IN-TICK by the RoundFlowResolver's deterministic cadence (which
## owns the LCG + countdown + per-match cap as rolled-back sim state). Spawns an emerald
## through SyncManager.spawn so it is rollback-correct on both peers, and wires its
## claimed->ripple ONCE on the genuine forward spawn. ox/oy = sim-unit offsets from
## centre, seed_v seeds its drift LCG. Returns true only if an emerald actually spawned
## (false when emerald_scene is null — the headless "freeze").
func _spawn_emerald_synced(ox: int, oy: int, seed_v: int) -> bool:
	if emerald_scene == null:
		return false
	var payload: Dictionary = {
		"px": SGFixed.from_int(ox),
		"py": SGFixed.from_int(oy),
		"seed": seed_v,
		"scan": str(_projectiles.get_path()) if _projectiles != null else "",
	}
	var em: Node = SyncManager.spawn("Emerald", self, emerald_scene, payload)
	if em == null:
		return false
	# Wire the screen-ripple presentation ONCE on the forward spawn (re-sims reuse the
	# node, so guard on is_in_rollback + is_connected against a double-connect).
	if not SyncManager.is_in_rollback() and em.has_signal(&"claimed") \
			and not em.claimed.is_connected(_on_emerald_claimed):
		em.claimed.connect(_on_emerald_claimed)
	return true


## The emerald was struck (a life granted): fire the screen ripple from its point.
func _on_emerald_claimed(world_pos: Vector3) -> void:
	_trigger_ripple(world_pos, emerald_ripple_strength)


# =====================================================================
# Casting / Stack / feedback
# =====================================================================

## A spell was STAGED (an attack pressed, or a counter slapped on): OPEN the
## presentation window (slow-mo dilation + telegraph). The clock is SHARED — a slap
## onto an open window does NOT re-open it. The deterministic resolution + winner
## reward are the StackResolver's job (the caster armed it from its own tick); this
## handler is presentation only, so it is suppressed during a rollback re-sim.
func _on_spell_staged(_card: CardResource) -> void:
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	if _stack != null and _stack.state != _stack.State.STACK_WINDOW:
		_stack.open_window()
	if _camera != null:
		_camera.add_trauma(card_cast_trauma)
	Sfx.play(&"stage_slap")
	# Sprint 23 batch 3: the stack window no longer slows time, so the "tape slow" cue was dropped (it
	# implied a slow-mo that no longer happens). _window_open_flag is kept for the resolve/KO bookkeeping.
	_window_open_flag = true


## The StackResolver resolved the stack on its deterministic tick (all staged spells
## fired, the winner banked its boost). This is PRESENTATION cleanup only — ramp speed
## back up, close the window (the HUD card pile flies away on stack_closed), and pop the
## winner banner. Suppressed during a rollback re-sim so a corrected tick doesn't
## re-fire it. [param winner_side]: 0 none / 1 player / 2 opponent.
func _on_resolver_resolved(winner_side: int) -> void:
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	_window_open_flag = false
	if _stack != null:
		_stack.close_window()  # NORMAL -> resume ramp + stack_closed (HUD card fly-away)
	if winner_side != 0 and match_state == MatchState.ROUND_ACTIVE:
		stack_winner_decided.emit(winner_side == 1)  # side 1 == the Player (blue) wizard


## An effect actually resolved (projectile fired / barrier deployed / wave
## loosed): impact feedback + barrier WOA wiring. Instant defense/counter
## casts do NOT open the Stack — only staged attacks telegraph.
func _on_spell_cast(projectile: Node, spell: SpellResource) -> void:
	if _camera != null:
		var trauma: float = card_cast_trauma if (spell != null and spell.is_card) else cast_trauma
		if spell is CardResource:
			trauma += spell.screen_shake_intensity
		# Phase 5: amplify the FIRING impact by 20% on every projectile spawn.
		_camera.add_trauma(trauma * fire_shake_multiplier)
	# A deployed barrier's capture drama (slow-mo + displacement wave + rumble + slam) is wired
	# reliably on SPAWN via _on_projectile_entered (Sprint 23) — NOT here. This spell_cast hook is
	# suppressed on rollback re-sims, which dropped the wiring for a barrier deployed on a rolled-
	# back tick, so its block silently produced no wave ("sometimes they don't happen").
	# LAUNCH MUZZLE BURST (Sprint 23 batch 2): a bright element-coloured pop at the spawn point on every
	# damaging launch (fireball / spark bolt), spraying down-court along the ball's travel — the visible
	# "kick" of the throw. Pure presentation; spell_cast is already rollback-suppressed at the caster.
	if projectile is FireballController and "damage" in projectile and projectile.damage > 0:
		var muzzle: Node3D = projectile.get_node_or_null(^"Visual") as Node3D
		if muzzle != null:
			var elem: int = projectile.element if "element" in projectile else Elements.FIRE
			var dir3 := Vector3(projectile.get_velocity_x() / 65536.0 * 0.6, 0.15,
					projectile.get_velocity_y() / 65536.0 * 0.6)
			BurstFX.spawn(projectile.get_parent(), muzzle.global_position, dir3,
					Elements.impact_color(elem), 16, maxf(4.0, dir3.length()), 0.075, 22.0)
	# Resolution SFX by effect type (placeholder set — see AUDIO_GUIDE.md).
	if projectile != null and projectile.has_signal(&"capture_charging"):
		Sfx.play(&"shield_deploy")
	elif projectile != null and "slow_ticks" in projectile and projectile.slow_ticks > 0:
		Sfx.play(&"counter_wave")
	elif spell != null and spell.is_card:
		Sfx.play(&"release_bolt")
	else:
		Sfx.play(&"cast_fireball")


## Wire a freshly-spawned barrier's capture presentation (reliable across rollback re-spawns — see
## the child_entered_tree hook in _ready). Non-barriers (fireballs / waves / shards) are ignored;
## idempotent via _set_conn. Replaces the old spell_cast wiring, which rollback suppressed.
func _on_projectile_entered(node: Node) -> void:
	if node is BarrierController:
		_set_conn(node.capture_started, _on_capture_started.bind(node), true)
		_set_conn(node.capture_charging, _on_capture_charging, true)
		_set_conn(node.capture_released, _on_capture_released, true)


## A shield CAUGHT a ball: ALWAYS fire the displacement wave (Sprint 23 CD: "sometimes they don't
## happen") + drop into the slow-mo anticipation hold. Both scale with the reflect intensity (WOA
## blended with incoming speed). The wave fires even during a stack window / death beat (it is just
## a shader pass); only the time DILATION is skipped when another system already owns the clock.
func _on_capture_started(intensity: float, barrier: Node) -> void:
	# Reflect intensity (0..1) scales the whole beat (wave + slow-mo + rumble + slam).
	_capture_intensity = clampf(intensity, 0.0, 1.0)
	# DISPLACEMENT WAVE — always. SIZE (strength) + SPEED (seconds) scale with intensity: small +
	# fast at low, large + slow (the dramatic one) at high.
	if barrier != null:
		var visual: Node3D = barrier.get_node_or_null(^"Visual") as Node3D
		if visual != null:
			var strength: float = lerpf(shield_ripple_strength_min, shield_ripple_strength_max, _capture_intensity)
			var seconds: float = lerpf(shield_ripple_seconds_min, shield_ripple_seconds_max, _capture_intensity)
			_trigger_ripple(visual.global_position + Vector3(0.0, 0.3, 0.0), strength, seconds)
	# Slow-mo anticipation HOLD — skipped only when a death beat or an open stack window already
	# owns the clock (the wave + rumble + slam still play through those).
	if _in_death_sequence:
		return
	# Sprint 23 batch 3: the stack window no longer dilates, so a shield catch DURING a window now slows
	# time too (the old "skip during a stack window" guard was removed).
	var time_scale: float = lerpf(shield_capture_time_scale_mild, shield_capture_time_scale, _capture_intensity)
	if _stack != null and time_scale < 0.999:
		_stack.hold_dilation(time_scale)
		_shield_slowmo_active = true


func _on_capture_charging(progress: float) -> void:
	if _camera != null:
		# A harder rumble builds through the hold (0.3 -> 0.9), SCALED by the reflect intensity
		# (a low-intensity block rumbles less — less anticipation; see _on_capture_started).
		var build: float = lerpf(0.3, 0.9, clampf(progress, 0.0, 1.0))
		_camera.set_rumble(build * lerpf(shield_rumble_min_scale, 1.0, _capture_intensity))


func _on_capture_released() -> void:
	# Resume normal speed if the shield slow-mo was ours (not during a death beat).
	if _shield_slowmo_active:
		_shield_slowmo_active = false
		if _stack != null and not _in_death_sequence:
			_stack.resume_speed()
	if _camera != null:
		_camera.set_rumble(0.0)
		# The release SLAM scales with the reflect intensity (light for a low-intensity block).
		_camera.add_trauma(lerpf(capture_release_trauma_min, capture_release_trauma, _capture_intensity))
	Sfx.play(&"shield_release")


func _on_wizard_damaged(amount: int, health: Node, trauma: float, hit_was_player: bool) -> void:
	if _camera != null:
		_camera.add_trauma(trauma)
	Sfx.play(&"hit_wizard")
	# IMPACT CRUNCH (Sprint 23): a brief HITSTOP freeze + a spark BURST at the struck wizard, scaled
	# / placed by the hit. Guarded against rollback re-sims so a corrected tick doesn't re-freeze or
	# spam particles. Presentation only — determinism untouched.
	if SyncManager == null or not SyncManager.is_in_rollback():
		# PLAYER-DAMAGE SLOW-MO (Sprint 23 batch 3): the hitstop crunch eases into a damage_slow_seconds
		# real-time slow-mo so the hit + its particles play out slow. SKIPPED on a LETHAL hit — the death
		# sequence owns the clock there (its own KO hitstop + death slow-mo + cam).
		var lethal: bool = health != null and health.has_method(&"get_health") and int(health.get_health()) <= 0
		if not lethal and _stack != null and _stack.has_method(&"hitstop"):
			var t: float = clampf(float(amount) / maxf(1.0, hitstop_ref_damage), 0.0, 1.0)
			var ms: int = int(lerpf(float(hitstop_min_ms), float(hitstop_max_ms), t))
			if damage_slow_seconds > 0.0:
				_stack.hitstop(ms, damage_slow_scale, damage_slow_seconds)
			else:
				_stack.hitstop(ms)  # 0 s = a brief crunch only, no slow-mo (the off switch)
		var hit_wizard: Node = _player if hit_was_player else _opponent
		var rig: Node3D = (hit_wizard.get_node_or_null(^"WizardRig") as Node3D) if hit_wizard != null else null
		if rig != null:
			BurstFX.spawn(rig.get_parent(), rig.global_position + Vector3(0.0, 0.9, 0.0),
					Vector3.UP, Elements.impact_color(health.get_last_hit_element() if (health != null and health.has_method(&"get_last_hit_element")) else Elements.FIRE), 26, 6.5, 0.09, 95.0)
	if hit_was_player:
		_stat_damage_taken += amount
	else:
		_stat_hits += 1
		_stat_damage_dealt += amount


# --- Local player charge rumble (sustained shake floor) ---

func _on_player_charge_started(_spell: SpellResource) -> void:
	_prev_charge_level = 0
	if _camera != null and charge_rumble_levels.size() > 0:
		_camera.set_rumble(charge_rumble_levels[0])


func _on_player_charge_level(level: int) -> void:
	if _camera != null and charge_rumble_levels.size() > 0:
		_camera.set_rumble(charge_rumble_levels[clampi(level, 0, charge_rumble_levels.size() - 1)])
		# A fresh gauge banking gives a sharp kick that grows per gauge (only on
		# the RISING edge — a draining charge must not machine-gun bursts).
		if level > _prev_charge_level and level > 0:
			_camera.add_trauma(charge_pop_trauma * float(level))
	_prev_charge_level = level


func _on_player_charge_ended() -> void:
	_prev_charge_level = 0
	if _camera != null:
		_camera.set_rumble(0.0)


func _on_player_cast_released(projectile: Node, _spell: SpellResource) -> void:
	if _camera != null:
		_camera.set_rumble(0.0)
		# RELEASE PUNCH (Sprint 23): the FOV kicks WIDER than base on firing, then smooths back.
		if _camera.has_method(&"fov_punch"):
			_camera.fov_punch()
	# Accuracy bookkeeping: only damaging launches count as throws (walls
	# and the 0-damage frost wave are excluded).
	if projectile != null and "damage" in projectile and projectile.damage > 0:
		_stat_throws += 1
		# LAUNCH KICK (Sprint 23 batch 2): a sharp camera jolt on the local player's own throw, layered
		# on the FOV punch above — the throw kicks back.
		if _camera != null:
			_camera.add_trauma(launch_kick_trauma)


## Results-screen stats (MatchFlowOverlay reads these — presentation only).
func get_stats() -> Dictionary:
	var foe_hp: int = 0
	var own_hp: int = 0
	if _opponent != null:
		var foe_health: Node = _opponent.get_node_or_null("Health")
		if foe_health != null:
			foe_hp = foe_health.get_health()
	if _player != null:
		var own_health: Node = _player.get_node_or_null("Health")
		if own_health != null:
			own_hp = own_health.get_health()
	var accuracy: int = 0
	if _stat_throws > 0:
		accuracy = clampi(roundi(100.0 * float(_stat_hits) / float(_stat_throws)), 0, 999)
	return {
		"foe_hp": foe_hp,
		"own_hp": own_hp,
		"throws": _stat_throws,
		"hits": _stat_hits,
		"accuracy": accuracy,
		"damage_dealt": _stat_damage_dealt,
		"damage_taken": _stat_damage_taken,
	}


func _on_player_spell_staged(_card: CardResource) -> void:
	if _camera != null:
		_camera.set_rumble(0.0)


# =====================================================================
# Round flow (best of 3)
# =====================================================================

## ROUND FLOW — presentation reactions to the RoundFlowResolver's deterministic sim
## beats. Each is GUARDED against rollback re-sims (a corrected tick must not re-fire
## the cinematics / re-announce), exactly like _on_resolver_resolved. The resolver owns
## the SIM (scores, reset); these handlers own the CINEMATICS + the UI signals.

## ACTIVE -> DEATH_WAIT: a KO landed this tick. Begin the slow-mo death beat. The
## resolver already banked the score + cancelled the stack IN-TICK, so here we only
## mirror + present. player_won_round = the Player (blue) won (the eliminated wizard is
## the Opponent); the death cam frames `not player_won_round` = the local Player dying.
func _on_resolver_ko(player_won_round: bool, match_over: bool) -> void:
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	_sync_mirror()
	_window_open_flag = false
	_set_sim_running(false)
	# Clear any open PRESENTATION window WITHOUT keeping normal speed — the death
	# sequence owns the dilation next (hold_dilation overrides the resume ramp).
	if _stack != null:
		_stack.close_window()
	# DEATH SEQUENCE (Sprint 20): slow-mo + death cam + bigger explosion + screen ripple
	# + the VICTORY/DEFEAT verdict. The resolver counts the death ticks to the break/match.
	_begin_death_sequence(not player_won_round, match_over, player_won_round)


## DEATH_WAIT -> POST_ROUND: the death beat elapsed; resume speed + raise the round
## result overlay + open the break (the resolver counts the break ticks to the reset).
func _on_resolver_break(player_won_round: bool, p_score: int, o_score: int) -> void:
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	_sync_mirror()
	_in_death_sequence = false
	_resume_from_death()
	round_ended.emit(player_won_round, p_score, o_score, post_round_seconds)
	Sfx.play(&"round_win" if player_won_round else &"round_lose")


## DEATH_WAIT -> OVER: the death beat elapsed on a match-ending KO; resume speed + raise
## the result screen.
func _on_resolver_match_concluded(player_won_match: bool) -> void:
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	_sync_mirror()
	_in_death_sequence = false
	_resume_from_death()
	match_ended.emit(player_won_match)
	Sfx.play(&"victory" if player_won_match else &"round_lose")


## POST_ROUND -> ACTIVE: the resolver reset the round IN-TICK (wizards + projectiles).
## Here we do the PRESENTATION reset (unpark the local sim, refresh the emerald spawner)
## + pop the round call-out.
func _on_resolver_round_reset(new_round_number: int) -> void:
	# A REMATCH (match reset -> round 1) on the CLIENT fires ONLY inside the rollback that applies
	# the host's synced play-again input: the client mispredicted "no rematch", so the OVER->ACTIVE
	# reset never re-runs on a confirmed forward tick. Skipping it during rollback would strand the
	# client on the result screen FOREVER (movement + the touch HUD gated off via round_started, the
	# victory overlay never hidden). The rematch is authoritative — both peers agreed via the synced
	# KEY_REMATCH — so presenting it mid-rollback is correct and never reverts. Between-round resets
	# (round 2/3) land on a confirmed countdown-zero tick on both peers, so they keep skipping
	# rollback re-sims (which could announce a mispredicted reset). (Sprint 22: online rematch fix.)
	if SyncManager != null and SyncManager.is_in_rollback() and new_round_number != 1:
		return
	_sync_mirror()
	# round_number == 1 means a FRESH MATCH (a rematch — the first round at match start is
	# announced directly in _ready, never via round_reset), so reset the match-scoped
	# presentation bookkeeping (stats for the next result screen, emerald budget).
	if new_round_number == 1:
		_stat_throws = 0
		_stat_hits = 0
		_stat_damage_dealt = 0
		_stat_damage_taken = 0
	_window_open_flag = false
	_set_sim_running(true)
	round_started.emit(new_round_number)
	_begin_round_intro()


## Begins the slow-mo knockout beat: dilate the world, zoom + track the eliminated
## wizard, fire the screen ripple, pop the VICTORY/DEFEAT verdict. The beat's END (resume
## speed + result overlay) is now the RoundFlowResolver's deterministic DEATH_WAIT
## countdown, NOT a wall-clock timer — so it lands on the same tick on both peers
## (death_seconds × tick_rate ticks span death_seconds of real time, even under slow-mo).
func _begin_death_sequence(ko_was_player: bool, match_over: bool, player_won_round: bool) -> void:
	_in_death_sequence = true
	var dying: Node = _player if ko_was_player else _opponent
	Sfx.play(&"knockout")

	# HARD KO HITSTOP (Sprint 23 batch 2): a sharp FREEZE lands FIRST (the kill's crunch), then the_stack
	# eases into the held death slow-mo when the freeze elapses (hitstop's then-hold-scale). Only when the
	# slow-mo is actually enabled (death_time_scale < 1.0); the collapsed-beat tests hold straight to 1.0.
	# Either way the slow-mo is HELD until _resume_from_death (the resolver's DEATH_WAIT countdown).
	if _stack != null:
		if _stack.has_method(&"hitstop") and death_time_scale < 0.999:
			_stack.hitstop(ko_hitstop_ms, death_time_scale)
		else:
			_stack.hold_dilation(death_time_scale)
	else:
		Engine.time_scale = clampf(death_time_scale, 0.05, 1.0)

	# Death cam: zoom onto the eliminated wizard's sprite and track the fling.
	if _camera != null:
		_camera.set_rumble(0.0)
		_camera.add_trauma(0.9)
		if dying != null and _camera.has_method(&"begin_death_cam"):
			var sprite: Node3D = dying.get_node_or_null(^"WizardRig/Sprite3D") as Node3D
			var rig: Node3D = dying.get_node_or_null(^"WizardRig") as Node3D
			# Tighter zoom on a win, gentler on a loss (Creative Director).
			var zoom: float = death_zoom_scale_win if player_won_round else death_zoom_scale_lose
			_camera.begin_death_cam(sprite if sprite != null else rig, zoom)

	# Screen-space shockwave from the point of contact.
	if dying != null:
		var dying_rig: Node3D = dying.get_node_or_null(^"WizardRig") as Node3D
		if dying_rig != null:
			_trigger_ripple(dying_rig.global_position + Vector3(0.0, 1.0, 0.0), death_ripple_strength)

	# VICTORY/DEFEAT verdict heading — emitted in the SAME frame the death cam begins so
	# the banner and the dolly zoom start together (Creative Director). The beat ENDS on
	# the resolver's DEATH_WAIT countdown (_on_resolver_break / _on_resolver_match_concluded),
	# not a wall-clock timer.
	knockout_began.emit(match_over, player_won_round)


## Resumes normal speed + releases the death cam at the END of the death beat. Called by
## the resolver's break / match-concluded handlers (the overlay raise + the break clock
## are now the resolver's deterministic tick, not this function's old wall-clock timer).
func _resume_from_death() -> void:
	if _stack != null:
		_stack.resume_speed()
	else:
		Engine.time_scale = 1.0
	if _camera != null and _camera.has_method(&"end_death_cam"):
		_camera.end_death_cam()


## Fires the retro-lens screen ripple (the displacement shockwave) from a WORLD
## point — reused by the knockout, a shield catching a fireball, and the emerald
## being struck. [param strength] is the peak UV displacement.
func _trigger_ripple(world_pos: Vector3, strength: float, seconds: float = -1.0) -> void:
	if _lens_mat == null or _camera == null:
		return
	var screen_px: Vector2 = _camera.unproject_position(world_pos)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	_lens_mat.set_shader_parameter(&"ripple_center", Vector2(screen_px.x / vp.x, screen_px.y / vp.y))
	_lens_mat.set_shader_parameter(&"ripple_strength", strength)
	# Expansion duration controls the wave SPEED — a per-ripple value (the shield's scales with
	# intensity), defaulting to the death/emerald duration.
	_ripple_seconds = death_ripple_seconds if seconds <= 0.0 else seconds
	_ripple_progress = 0.0
	_ripple_active = true


## Parks/resumes the deterministic sim between rounds by switching the local
## tick drivers (the rollback SyncManager replaces this seam later).
func _set_sim_running(running: bool) -> void:
	if _netplay:
		return  # SyncManager owns tick driving in netplay — never touch local drivers.
	for wizard in [_player, _opponent]:
		if wizard != null and "local_tick_driver_enabled" in wizard:
			wizard.local_tick_driver_enabled = running


## ROUND INTRO (Sprint 23 batch 3): park the local sim for round_intro_seconds at a round start so the
## ROUND-N title plays + flies off before the action begins ("ready, GO"). OFFLINE only — in netplay
## _set_sim_running is a no-op (SyncManager owns the ticks), so the title just plays over the live
## round. _process unparks when the deadline elapses. Skipped when round_intro_seconds <= 0 (tests).
func _begin_round_intro() -> void:
	if _netplay or round_intro_seconds <= 0.0:
		return
	_set_sim_running(false)
	_round_intro_until_msec = Time.get_ticks_msec() + int(round_intro_seconds * 1000.0)


## NETPLAY ENTRY (Sprint 21): if NetworkManager has a networked match active, hand
## the two wizards to the rollback SyncManager instead of the local tick drivers.
## Deterministic ownership: the HOST owns Player, the CLIENT owns Opponent (both
## peers compute the same pair from self/remote ids). Removes the opponent AI and
## kicks the scene-load handshake; SyncManager.start() fires once both peers
## confirm the arena scene is loaded (see NetworkManager / rollback_session.gd).
func _enter_netplay() -> void:
	var nm: Node = get_node_or_null(^"/root/NetworkManager")
	if nm == null or not nm.netplay:
		return
	_netplay = true
	# Remove the AI so a REMOTE human drives the opponent wizard.
	if _opponent != null:
		var ai: Node = _opponent.get_node_or_null(^"AIBrain")
		if ai != null:
			ai.queue_free()
	var my_id: int = multiplayer.get_unique_id()
	var remote_id: int = int(nm.remote_peer_id)
	var is_host: bool = multiplayer.is_server()
	var host_id: int = my_id if is_host else remote_id
	var client_id: int = remote_id if is_host else my_id
	var casting: bool = bool(nm.netplay_casting_enabled)
	if _player != null and _player.has_method(&"set_netplay"):
		_player.set_netplay(host_id, casting)
	if _opponent != null and _opponent.has_method(&"set_netplay"):
		_opponent.set_netplay(client_id, casting)
	# The StackResolver is a scene-authored sim node (like the wizards), so it joins
	# the network_sync group HERE — before the handshake's SyncManager.start() scan —
	# not via the spawn-time check the projectiles use.
	if _resolver != null and _resolver.has_method(&"set_netplay"):
		_resolver.set_netplay()
	# The RoundFlowResolver joins the same way (scene-authored sim node), so its KO
	# poll + the round reset run on synced ticks once the handshake starts.
	if _roundflow != null and _roundflow.has_method(&"set_netplay"):
		_roundflow.set_netplay()
	# Re-point the fireball cast button's charge ring at the LOCAL wizard's caster. The
	# button hard-codes the blue Player; the CLIENT owns the red Opponent, so without this
	# its charge ring shows — and reacts to — the WRONG player's charge (playtest report:
	# "red's UI doesn't change; blue's UI controls red's"). Host: local == Player (no-op).
	var local_wizard: Node = _player if is_host else _opponent
	var cast_btn: Node = get_node_or_null(^"MatchHUD/CastButton")
	if cast_btn != null and cast_btn.has_method(&"set_caster") and local_wizard != null:
		cast_btn.set_caster(local_wizard.get_node_or_null(^"SpellCasterComponent"))
	# Re-point the card-hand HUD at the LOCAL wizard's CardCasterComponent — same client
	# perspective fix: the HUD hard-binds the blue Player, so the CLIENT (red Opponent) needs
	# it retargeted or its card casts + cooldown dims never animate. Host: local == Player (no-op).
	var card_hand: Node = get_node_or_null(^"CardHandHUD")
	if card_hand != null and card_hand.has_method(&"set_caster") and local_wizard != null:
		card_hand.set_caster(local_wizard.get_node_or_null(^"CardCasterComponent"))
	# CLIENT VIEW (visual mirror): each player should see THEIR OWN wizard in the
	# near, well-lit foreground. The HOST owns Player (already near) — nothing to do.
	# The CLIENT owns Opponent (normally the FAR wizard), so the court is MIRRORED
	# front-to-back (VisualBridge.view_flip_z negates visual Z only — X kept so
	# left/right controls stay correct), the client's wizard renders at the near
	# baseline, and the AUTHORED camera points at it. The view_flip_z itself is now
	# self-computed in EVERY VisualBridgeComponent._ready from the netplay role, so
	# mid-match spawns (projectiles, emerald) mirror too — here we only do the
	# scene-level client wiring (camera + HUD). Pure presentation; sim identical.
	if not is_host:
		if _camera != null and _camera.has_method(&"set_follow_target") and _opponent != null:
			_camera.set_follow_target(_opponent.get_node_or_null(^"WizardRig") as Node3D)
		# HUD: the client's wizard is the Opponent, so swap which health bar reads
		# as "yours" — the corner bar mirrors the Opponent (own), the floating bar
		# mirrors the Player (foe) and hovers over the far blue wizard.
		var hud: Node = get_node_or_null(^"MatchHUD")
		if hud != null and hud.has_method(&"set_perspective_flipped") and _player != null and _opponent != null:
			hud.set_perspective_flipped(
					_opponent.get_node_or_null(^"Health"),
					_player.get_node_or_null(^"Health"),
					_player.get_node_or_null(^"WizardRig") as Node3D)
		# Charge-rumble + throw-stat feedback (Phase 2c retarget MISS): wired to the blue
		# Player in _ready, but the CLIENT controls the red Opponent — move it, else the
		# host's fireball charge shakes the CLIENT's screen (playtest report).
		_wire_local_charge_feedback(_player, false)
		_wire_local_charge_feedback(_opponent, true)
	var mine: String = "Player (blue, near)" if (_player != null and _player.is_multiplayer_authority()) else "Opponent (red, far)"
	print("[NETPLAY] peer uid=%d (host=%s) controls the %s wizard" % [my_id, str(is_host), mine])
	# Kick the deterministic handshake.
	nm.notify_scene_loaded()


# =====================================================================
# Helpers
# =====================================================================

## Copies the RoundFlowResolver's authoritative (rolled-back) sim state into the UI
## read-surface mirror (player_score / opponent_score / round_number / match_state).
## Called per-frame in _process AND synchronously from every resolver signal handler —
## the handler call is what makes the mirror current the INSTANT a signal fires
## (SceneTree.process_frame is emitted BEFORE _process, so a listener that reads
## match_state right after awaiting a signal would otherwise see a one-frame-stale value).
func _sync_mirror() -> void:
	if _roundflow == null:
		return
	player_score = _roundflow.get_player_score()
	opponent_score = _roundflow.get_opponent_score()
	round_number = _roundflow.get_round_number()
	match_state = _phase_to_state(_roundflow.get_phase())


## Maps the RoundFlowResolver's sim phase to the legacy MatchState the UI + tests read.
## DEATH_WAIT and POST_ROUND both present as POST_ROUND (the round is between active
## play); OVER becomes MATCH_OVER (reached only once the death beat has elapsed).
func _phase_to_state(phase: int) -> MatchState:
	match phase:
		RoundFlowResolver.Phase.OVER:
			return MatchState.MATCH_OVER
		RoundFlowResolver.Phase.ACTIVE:
			return MatchState.ROUND_ACTIVE
		_:
			return MatchState.POST_ROUND


## The wizard the LOCAL peer controls in netplay (the multiplayer-authority one) — where a
## synced play-again request is latched. Null before netplay entry; offline the rematch
## takes the direct path and never calls this.
func _local_wizard() -> Node:
	if _player != null and _player.is_multiplayer_authority():
		return _player
	if _opponent != null and _opponent.is_multiplayer_authority():
		return _opponent
	return null


## AIM ARROW (Mobile-MP B2b): point the glowing ground arrow at the LOCAL wizard's
## firing angle while it CHARGES a fireball or has an OWNED spell staged on the stack;
## hide it otherwise. The down-court sign comes from the FOE's rig Z (which already
## encodes the client's view_flip_z mirror); the lateral offset is world +X (sim vx is
## never flipped) — so the arrow matches the ball's visual travel on BOTH peers.
func _update_aim_arrow() -> void:
	if _aim_arrow == null:
		return
	var wiz: Node = _local_wizard()
	if wiz == null:
		wiz = _player   # offline / pre-netplay: the human drives the blue Player
	if wiz == null:
		_aim_arrow.hide_arrow()
		return
	var spell_caster: Node = _find_child_of(wiz, "SpellCasterComponent")
	var card_caster: Node = _find_child_of(wiz, "CardCasterComponent")
	var charging: bool = spell_caster != null and spell_caster.is_charging()
	var staging: bool = card_caster != null and card_caster.is_staging()
	if not (charging or staging):
		_aim_arrow.hide_arrow()
		return
	var rig: Node3D = wiz.get_node_or_null(^"WizardRig") as Node3D
	var foe: Node = _opponent if wiz == _player else _player
	var foe_rig: Node3D = (foe.get_node_or_null(^"WizardRig") as Node3D) if foe != null else null
	if rig == null or foe_rig == null:
		_aim_arrow.hide_arrow()
		return
	# lateral fraction = sector / AIM_SECTORS x aim_max_fraction (== vx / |vy|).
	var frac: float = 0.0
	if spell_caster != null and InputCommand.AIM_SECTORS > 0:
		frac = float(spell_caster.get_aim_sector()) / float(InputCommand.AIM_SECTORS) \
				* float(spell_caster.aim_max_fraction)
	var dz: float = signf(foe_rig.global_position.z - rig.global_position.z)
	if dz == 0.0:
		dz = -1.0
	_aim_arrow.point(rig.global_position, Vector3(frac, 0.0, dz).normalized())


## Connects (or disconnects) the LOCAL-player charge/cast FEEDBACK — the camera charge
## rumble + the throw stat — to [param wizard]'s casters. Retargets the feedback from the
## blue Player to the client's red Opponent in netplay (the Phase 2c HUD-retarget pass
## missed the rumble, so the host's charging shook the client's screen).
func _wire_local_charge_feedback(wizard: Node, connect_it: bool) -> void:
	if wizard == null:
		return
	for caster in wizard.get_children():
		if caster is SpellCasterComponent or caster is CardCasterComponent:
			_set_conn(caster.cast_charge_started, _on_player_charge_started, connect_it)
			_set_conn(caster.cast_charge_level_changed, _on_player_charge_level, connect_it)
			_set_conn(caster.cast_charge_canceled, _on_player_charge_ended, connect_it)
			_set_conn(caster.spell_cast, _on_player_cast_released, connect_it)
		# CHARGE ZOOM (Sprint 22): point the camera FOV charge-zoom at the LOCAL wizard's fireball
		# caster (retargeted to the client's own wizard on connect, exactly like the rumble above).
		if connect_it and caster is SpellCasterComponent and _camera != null and _camera.has_method(&"set_charge_source"):
			_camera.set_charge_source(caster)
	var card_caster: Node = _find_child_of(wizard, "CardCasterComponent")
	if card_caster != null:
		_set_conn(card_caster.spell_staged, _on_player_spell_staged, connect_it)


## Idempotent connect/disconnect of [param sig] -> [param target] (avoids double-wiring).
func _set_conn(sig: Signal, target: Callable, want: bool) -> void:
	if want and not sig.is_connected(target):
		sig.connect(target)
	elif not want and sig.is_connected(target):
		sig.disconnect(target)


func _is_under_player(node: Node) -> bool:
	if _player == null:
		return false
	var walker: Node = node
	while walker != null:
		if walker == _player:
			return true
		walker = walker.get_parent()
	return false


func _find_child_of(parent: Node, type_name: String) -> Node:
	for child in parent.get_children():
		if child.get_script() != null and child.is_class("Node"):
			if child.get_script().get_global_name() == StringName(type_name):
				return child
	return null
