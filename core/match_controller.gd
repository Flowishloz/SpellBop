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

## Spawn baselines (sim units) used for the round reset.
@export var player_spawn_y: float = 880.0
@export var opponent_spawn_y: float = -880.0

## Camera trauma per event (0..1; displayed shake is trauma squared).
@export var cast_trauma: float = 0.15
@export var card_cast_trauma: float = 0.3
@export var player_hit_trauma: float = 0.5
@export var opponent_hit_trauma: float = 0.25
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
## Peak UV displacement of the shield-contact and emerald screen ripples.
@export var shield_ripple_strength: float = 0.045
@export var emerald_ripple_strength: float = 0.04

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

# stack_winner_speed_multiplier cached to fixed-point (1.5 -> 98304).
var _stack_winner_boost_fp: int = 98304

# HEALING EMERALD spawner state. The cadence counts SIM ticks (only while a round
# is live, in _physics_process) so it is deterministic; only one emerald is on the
# field at a time. _emerald_rng is the seeded LCG for interval + spawn position.
var _emerald: Node = null
var _emerald_rng: int = 0
var _emerald_countdown: int = 0
# Emeralds spawned so far THIS MATCH (capped at emerald_max_per_match; reset only
# on a fresh match in request_rematch — persists across rounds).
var _emeralds_spawned_this_match: int = 0

# DEATH SEQUENCE state (Sprint 20). The retro-lens material drives the screen
# ripple; _ripple_* tracks the active shockwave; _in_death_sequence guards the
# parked POST_ROUND/MATCH_OVER flow so the next round / a rematch can't start
# until the death beat finishes.
var _lens_mat: ShaderMaterial = null
var _ripple_active: bool = false
var _ripple_progress: float = 0.0
var _in_death_sequence: bool = false
# True while a shield capture-hold is dilating time (so capture_released knows to
# resume). Guards against resuming when the slow-mo wasn't ours to begin with.
var _shield_slowmo_active: bool = false

# Tracks the window's open state so the tape-slow cue plays only on the
# NORMAL -> WINDOW transition, not on every counter-slap refresh.
var _window_open_flag: bool = false

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
	_stack_winner_boost_fp = SGFixed.from_float(maxf(1.0, stack_winner_speed_multiplier))
	_reseed_emeralds()

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

	# Damage feedback: every wizard's hits shake the camera (presentation + stats).
	# ROUND FLOW (KO -> round end) is the RoundFlowResolver's job now — it POLLS HP on
	# its own tick. The knocked_out SIGNAL re-fires on a rollback re-sim and would
	# double-count the score, so it is NOT used for round flow (see round_flow_resolver.gd).
	for health in find_children("*", "HealthComponent", true, false):
		var is_player_side: bool = _is_under_player(health)
		var trauma: float = player_hit_trauma if is_player_side else opponent_hit_trauma
		health.damaged.connect(_on_wizard_damaged.bind(trauma, is_player_side))

	# Charge-up rumble: LOCAL player's casters only (see player_path doc).
	if _player != null:
		for caster in _player.get_children():
			if caster is SpellCasterComponent or caster is CardCasterComponent:
				caster.cast_charge_started.connect(_on_player_charge_started)
				caster.cast_charge_level_changed.connect(_on_player_charge_level)
				caster.cast_charge_canceled.connect(_on_player_charge_ended)
				caster.spell_cast.connect(_on_player_cast_released)
		var card_caster: Node = _find_child_of(_player, "CardCasterComponent")
		if card_caster != null:
			card_caster.spell_staged.connect(_on_player_spell_staged)

	_enter_netplay()
	round_started.emit(round_number)
	_warm_up_render_pipelines()
	_build_arena_borders()


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
		for child in inst.get_children():
			if child is Node3D:
				(child as Node3D).position = Vector3(0, -0.9, 6)
		parked.append(inst)
	BurstFX.spawn(self, Vector3(0, -0.9, 6), Vector3.UP, Color(1, 0.55, 0.2, 0.9), 4, 1.0)
	BurstFX.spawn(self, Vector3(0, -0.9, 6), Vector3.UP, Color(0.45, 0.9, 0.6, 0.9), 4, 1.0)
	BurstFX.spawn(self, Vector3(0, -0.9, 6), Vector3.UP, Color(0.55, 0.8, 1.0, 0.9), 4, 1.0)
	BurstFX.spawn_wall_pulse(self, Vector3(0, -0.9, 6), 1)
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
	# PRESENTATION MIRROR (Sub-phase 3): keep the UI read-surface fields in lockstep
	# with the RoundFlowResolver's authoritative (rolled-back) sim state every frame,
	# so a mispredicted-then-rolled-back KO can never leave the scoreboard / state
	# drifted (the signal handlers below are rollback-guarded; this passive sync is not).
	_sync_mirror()
	# Desktop convenience: SPACE restarts a finished match (the on-screen PLAY AGAIN
	# button is the primary trigger). Offline only — a synced online rematch is a
	# separate feature, and a local press must never desync a live netplay session.
	if match_state == MatchState.MATCH_OVER and not _netplay:
		if Input.is_action_just_pressed("cast_spell"):
			request_rematch()


## Advances the screen-space death ripple on SCALED time (so the shockwave expands
## slowly during the death slow-mo, like the rest of the 3D), then clears it.
func _update_death_ripple(delta: float) -> void:
	if not _ripple_active or _lens_mat == null:
		return
	_ripple_progress += delta / maxf(0.0001, death_ripple_seconds)
	_lens_mat.set_shader_parameter(&"ripple_progress", _ripple_progress)
	if _ripple_progress >= 1.0:
		_ripple_active = false
		_lens_mat.set_shader_parameter(&"ripple_progress", -1.0)


## Restart the match from a fresh scoreboard (the PLAY AGAIN button + the SPACE
## shortcut both route here). No-op unless the match is actually over.
func request_rematch() -> void:
	# Offline / local only: a synced online rematch is a separate feature (the match
	# just ends online), and a local SPACE/button press must never reset one peer's
	# sim out from under the other.
	if match_state != MatchState.MATCH_OVER or _netplay:
		return
	_stat_throws = 0
	_stat_hits = 0
	_stat_damage_dealt = 0
	_stat_damage_taken = 0
	_emeralds_spawned_this_match = 0  # a fresh match refills the emerald budget
	# Reset the sim authority (scores 0, round 1, both wizards + projectiles). OVER is
	# quiescent, so this off-tick reset is the same risk profile as the old _begin_round.
	if _roundflow != null:
		_roundflow.reset_match()
	player_score = 0
	opponent_score = 0
	round_number = 1
	match_state = MatchState.ROUND_ACTIVE
	_window_open_flag = false
	_set_sim_running(true)
	_clear_emerald()
	_reseed_emeralds()
	round_started.emit(round_number)


# =====================================================================
# Healing emerald (Phase 1)
# =====================================================================

## DETERMINISM-ALIGNED TICK CADENCE: counts sim ticks only while a round is live
## (the wizards' tick drivers run in the same physics frames), so the spawn
## timing is deterministic. A fresh emerald spawns every interval, retiring any
## un-claimed predecessor so exactly one is ever on the field. NETPLAY: converts
## to a tick-counted spawn with the rollback sprint, like the stack window.
func _physics_process(_delta: float) -> void:
	# NETPLAY: the emerald spawner isn't rollback-routed yet (Sprint 21) — keep it
	# off so it can't desync the deterministic sim. Re-enabled in the spawn sprint.
	if match_state != MatchState.ROUND_ACTIVE or emerald_scene == null or _netplay:
		return
	if _emerald != null and not is_instance_valid(_emerald):
		_emerald = null  # claimed/freed — the clock re-arms below
	# ONE emerald at a time, and at most emerald_max_per_match across the MATCH
	# (Sprint 20). While one is floating, or the match budget is spent, the
	# countdown waits — no refresh of an un-claimed emerald.
	if _emerald != null or _emeralds_spawned_this_match >= emerald_max_per_match:
		return
	_emerald_countdown -= 1
	if _emerald_countdown <= 0:
		_spawn_emerald()
		_emerald_countdown = _next_emerald_interval_ticks()


## Instantiates an emerald near the arena centre (parented under the arena, NOT
## the Projectiles container, so it never perturbs projectile-count logic) and
## points its strike scan at the Projectiles container.
func _spawn_emerald() -> void:
	if emerald_scene == null:
		return
	var em: Node = emerald_scene.instantiate()
	add_child(em)
	var ox: int = (_next_emerald_rng() % 281) - 140   # -140..140 sim units
	var oy: int = (_next_emerald_rng() % 361) - 180    # -180..180 sim units
	if em.has_method(&"set_global_fixed_position"):
		em.set_global_fixed_position(SGFixed.vector2(SGFixed.from_int(ox), SGFixed.from_int(oy)))
		em.sync_to_physics_engine()
	if em.has_method(&"set_scan_container") and _projectiles != null:
		em.set_scan_container(_projectiles)
	if em.has_method(&"seed_drift"):
		em.seed_drift(_next_emerald_rng())
	if em.has_method(&"emit_position"):
		em.emit_position()
	if em.has_signal(&"claimed"):
		em.claimed.connect(_on_emerald_claimed)
	_emerald = em
	_emeralds_spawned_this_match += 1


## The emerald was struck (a life granted): fire the screen ripple from its point.
func _on_emerald_claimed(world_pos: Vector3) -> void:
	_trigger_ripple(world_pos, emerald_ripple_strength)


## Whole ticks until the next emerald (emerald_min..max seconds), from the LCG.
func _next_emerald_interval_ticks() -> int:
	var min_ticks: int = maxi(1, int(emerald_min_interval_seconds * 60.0))
	var span_ticks: int = maxi(1, int((emerald_max_interval_seconds - emerald_min_interval_seconds) * 60.0))
	return min_ticks + (_next_emerald_rng() % span_ticks)


## Advances the seeded LCG (masked to 32 bits so the multiply never overflows).
func _next_emerald_rng() -> int:
	_emerald_rng = (_emerald_rng * 1664525 + 1013904223) & 0xffffffff
	return _emerald_rng


## (Re)seed the spawn cadence for the current round (mixing the round number so
## rounds differ but replay identically) and arm the first countdown.
func _reseed_emeralds() -> void:
	_emerald_rng = (emerald_seed + round_number * 2654435761) & 0xffffffff
	_emerald_countdown = _next_emerald_interval_ticks()


## Frees the live emerald (round reset / KO) so it never lingers into the break.
func _clear_emerald() -> void:
	if _emerald != null and is_instance_valid(_emerald):
		_emerald.queue_free()
	_emerald = null


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
	# Tape-slow cue on the actual slow-mo ENGAGE (slaps don't re-warble).
	if not _window_open_flag:
		_window_open_flag = true
		Sfx.play(&"tape_slow")


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
	# A deployed barrier's capture drama: the catch drops the world into slow-mo
	# (the WOA anticipation, now clearly visible), rumble builds through the hold,
	# and a heavy slam + a screen ripple punctuate the release.
	if projectile != null and projectile.has_signal(&"capture_charging"):
		if projectile.has_signal(&"capture_started"):
			projectile.capture_started.connect(_on_capture_started.bind(projectile))
		projectile.capture_charging.connect(_on_capture_charging)
		projectile.capture_released.connect(_on_capture_released)
	# Resolution SFX by effect type (placeholder set — see AUDIO_GUIDE.md).
	if projectile != null and projectile.has_signal(&"capture_charging"):
		Sfx.play(&"shield_deploy")
	elif projectile != null and "slow_ticks" in projectile and projectile.slow_ticks > 0:
		Sfx.play(&"counter_wave")
	elif spell != null and spell.is_card:
		Sfx.play(&"release_bolt")
	else:
		Sfx.play(&"cast_fireball")


## A shield CAUGHT a ball: drop into slow-mo for the anticipation hold (so the WOA
## reflect is clearly visible) and fire a screen ripple from the wall. Skipped if
## a death beat owns the dilation, or already dilated (a stack window).
func _on_capture_started(barrier: Node) -> void:
	if _in_death_sequence:
		return
	if _stack != null and _stack.state == _stack.State.STACK_WINDOW:
		return
	if _stack != null and shield_capture_time_scale < 0.999:
		_stack.hold_dilation(shield_capture_time_scale)
		_shield_slowmo_active = true
	# Screen ripple at the wall (the point of contact).
	if barrier != null:
		var visual: Node3D = barrier.get_node_or_null(^"Visual") as Node3D
		if visual != null:
			_trigger_ripple(visual.global_position + Vector3(0.0, 0.3, 0.0), shield_ripple_strength)


func _on_capture_charging(progress: float) -> void:
	if _camera != null:
		# Sprint 20 round-4: a harder rumble builds through the hold (0.3 -> 0.9).
		_camera.set_rumble(lerpf(0.3, 0.9, clampf(progress, 0.0, 1.0)))


func _on_capture_released() -> void:
	# Resume normal speed if the shield slow-mo was ours (not during a death beat).
	if _shield_slowmo_active:
		_shield_slowmo_active = false
		if _stack != null and not _in_death_sequence:
			_stack.resume_speed()
	if _camera != null:
		_camera.set_rumble(0.0)
		_camera.add_trauma(capture_release_trauma)
	Sfx.play(&"shield_release")


func _on_wizard_damaged(amount: int, trauma: float, hit_was_player: bool) -> void:
	if _camera != null:
		_camera.add_trauma(trauma)
	Sfx.play(&"hit_wizard")
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
	# Accuracy bookkeeping: only damaging launches count as throws (walls
	# and the 0-damage frost wave are excluded).
	if projectile != null and "damage" in projectile and projectile.damage > 0:
		_stat_throws += 1


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
	_clear_emerald()
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
	if SyncManager != null and SyncManager.is_in_rollback():
		return
	_sync_mirror()
	_window_open_flag = false
	_set_sim_running(true)
	_clear_emerald()
	_reseed_emeralds()
	round_started.emit(new_round_number)


## Begins the slow-mo knockout beat: dilate the world, zoom + track the eliminated
## wizard, fire the screen ripple, pop the VICTORY/DEFEAT verdict. The beat's END (resume
## speed + result overlay) is now the RoundFlowResolver's deterministic DEATH_WAIT
## countdown, NOT a wall-clock timer — so it lands on the same tick on both peers
## (death_seconds × tick_rate ticks span death_seconds of real time, even under slow-mo).
func _begin_death_sequence(ko_was_player: bool, match_over: bool, player_won_round: bool) -> void:
	_in_death_sequence = true
	var dying: Node = _player if ko_was_player else _opponent

	# Death slow-mo, HELD until _resume_from_death (driven by the resolver's DEATH_WAIT
	# countdown) resumes normal speed.
	if _stack != null:
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
func _trigger_ripple(world_pos: Vector3, strength: float) -> void:
	if _lens_mat == null or _camera == null:
		return
	var screen_px: Vector2 = _camera.unproject_position(world_pos)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	_lens_mat.set_shader_parameter(&"ripple_center", Vector2(screen_px.x / vp.x, screen_px.y / vp.y))
	_lens_mat.set_shader_parameter(&"ripple_strength", strength)
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
