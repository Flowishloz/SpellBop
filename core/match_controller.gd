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
## TIMING NOTE: round-flow timers are wall-clock presentation orchestration
## (the sim is parked between rounds — tick drivers disabled). When rollback
## lands, round transitions become agreed ticks; this file is where that
## conversion happens.
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
var _post_round_deadline_msec: int = 0

# THE STACK (MTG-style): casters with a staged spell, in slap order. When
# the countdown window expires the stack resolves LIFO — the latest response
# (a counter) fires before the spell it answered.
var _stack_entries: Array[Node] = []

# The wizard body that won the most recent stack (last responder). Captured when
# the window closes, rewarded (and cleared) after the staggered resolution ends.
var _stack_winner: Node = null

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
	for caster in find_children("*", "CardCasterComponent", true, false):
		caster.spell_cast.connect(_on_spell_cast)
		# STAGING is the Stack moment: the countdown telegraphs the spell and
		# gates the counters; THIS controller releases the stack LIFO when
		# the window expires (the timer and the release are the same event).
		caster.spell_staged.connect(_on_spell_staged.bind(caster))
	if _stack != null:
		_stack.stack_closed.connect(_on_stack_closed)

	# Damage feedback + ROUND FLOW: every wizard's hits shake the camera;
	# a KO ends the round.
	for health in find_children("*", "HealthComponent", true, false):
		var is_player_side: bool = _is_under_player(health)
		var trauma: float = player_hit_trauma if is_player_side else opponent_hit_trauma
		health.damaged.connect(_on_wizard_damaged.bind(trauma, is_player_side))
		health.knocked_out.connect(_on_knocked_out.bind(is_player_side))

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
	# The death beat owns the screen — no round transition / rematch until it ends.
	if _in_death_sequence:
		return
	match match_state:
		MatchState.POST_ROUND:
			if Time.get_ticks_msec() >= _post_round_deadline_msec:
				_begin_round()
		MatchState.MATCH_OVER:
			# Desktop convenience: SPACE still restarts. The on-screen PLAY AGAIN
			# button (MatchFlowOverlay) is the primary trigger and calls
			# request_rematch() directly.
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
	if match_state != MatchState.MATCH_OVER:
		return
	player_score = 0
	opponent_score = 0
	round_number = 0
	_stat_throws = 0
	_stat_hits = 0
	_stat_damage_dealt = 0
	_stat_damage_taken = 0
	_emeralds_spawned_this_match = 0  # a fresh match refills the emerald budget
	_begin_round()


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

## A spell was STAGED (attack channel paid, or a counter slapped on top):
## push the caster onto the stack. The clock is SHARED — a slap on top of
## an existing window does NOT restart it; everything resolves together
## when the one countdown expires (Creative Director). Entries are NOT
## deduped: one caster may have several spells on the stack (its
## release_staged() pops them newest-first, preserving global LIFO).
func _on_spell_staged(_card: CardResource, caster: Node) -> void:
	_stack_entries.append(caster)
	if _stack != null and _stack.state != _stack.State.STACK_WINDOW:
		_stack.open_window()
	if _camera != null:
		_camera.add_trauma(card_cast_trauma)
	Sfx.play(&"stage_slap")
	# Tape-slow cue on the actual slow-mo ENGAGE (slaps don't re-warble).
	if not _window_open_flag:
		_window_open_flag = true
		Sfx.play(&"tape_slow")


## The countdown expired: resolve the stack. SIMULTANEOUS RESOLUTION (Creative
## Director playtest preference — reverting the Sprint-20 one-at-a-time stagger):
## ALL staged spells fire AT ONCE, then normal speed resumes. The release order
## stays LIFO (newest first) only so a counter is loosed just before the spell it
## answered within the same frame. NETPLAY NOTE: the release originates from the
## wall-clock window today; it becomes a tick-counted event with the rollback sprint.
func _on_stack_closed() -> void:
	_window_open_flag = false
	if match_state != MatchState.ROUND_ACTIVE:
		_stack_entries.clear()
		_stack_winner = null
		# A KO / forced close already drove resume_speed(); nothing to resolve.
		return
	# WINNER (last-responder-always, Creative Director): the player who placed the
	# NEWEST spell on the stack wins it. Captured BEFORE clearing; the +50%
	# next-throw reward is granted AFTER the stack resolves so it lands on their
	# NEXT throw, not a spell currently resolving.
	_stack_winner = _winning_wizard()
	var entries: Array[Node] = _stack_entries.duplicate()
	_stack_entries.clear()
	entries.reverse()  # newest-first == LIFO (same-frame fire order)
	for caster in entries:
		if is_instance_valid(caster) and caster.has_method(&"release_staged"):
			caster.release_staged()
	if _stack != null:
		_stack.resume_speed()
	_award_stack_winner()


## Grants the captured stack winner a one-shot speed boost on its NEXT fired
## projectile and announces the result (Phase 3 indicator hook).
func _award_stack_winner() -> void:
	if _stack_winner != null and is_instance_valid(_stack_winner) \
			and _stack_winner.has_method(&"grant_speed_boost"):
		_stack_winner.grant_speed_boost(_stack_winner_boost_fp)
		stack_winner_decided.emit(_stack_winner == _player)
	_stack_winner = null


## The wizard body that placed the NEWEST spell on the stack (its caster is the
## last appended entry) — the last responder, who always wins. null if empty.
func _winning_wizard() -> Node:
	if _stack_entries.is_empty():
		return null
	return _wizard_root_of(_stack_entries[-1])


## Walks up from a caster component to the wizard root (Player / Opponent) it
## belongs to, so the reward can target that whole wizard.
func _wizard_root_of(node: Node) -> Node:
	var walker: Node = node
	while walker != null:
		if walker == _player or walker == _opponent:
			return walker
		walker = walker.get_parent()
	return null


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

func _on_knocked_out(ko_was_player: bool) -> void:
	if match_state != MatchState.ROUND_ACTIVE:
		return
	var player_won_round: bool = not ko_was_player
	if player_won_round:
		player_score += 1
	else:
		opponent_score += 1

	_set_sim_running(false)
	_stack_entries.clear()
	_clear_emerald()

	# State changes BEFORE close_window(): _on_stack_closed must see the
	# round as over so a KO never releases staged spells into the break.
	var match_over: bool = player_score >= rounds_to_win or opponent_score >= rounds_to_win
	match_state = MatchState.MATCH_OVER if match_over else MatchState.POST_ROUND

	# Clear any open stack window (the handler no-ops now the round is over)
	# WITHOUT keeping normal speed — the death sequence owns the dilation next.
	if _stack != null:
		_stack.close_window()

	# DEATH SEQUENCE (Sprint 20): slow-mo + death cam + bigger explosion + screen
	# ripple + the VICTORY/DEFEAT verdict; the result overlay (and the break clock)
	# wait death_sequence_seconds while the knockout animation plays.
	_begin_death_sequence(ko_was_player, match_over, player_won_round)


## Begins the slow-mo knockout beat: dilate the world, zoom + track the eliminated
## wizard, fire the screen ripple, pop the VICTORY/DEFEAT verdict, and schedule the
## result overlay after death_sequence_seconds of REAL time (dilation-immune).
func _begin_death_sequence(ko_was_player: bool, match_over: bool, player_won_round: bool) -> void:
	_in_death_sequence = true
	var dying: Node = _player if ko_was_player else _opponent

	# Death slow-mo, HELD until _finish_death_sequence resumes normal speed.
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

	# VICTORY/DEFEAT verdict heading — emitted in the SAME frame the death cam
	# begins so the banner and the dolly zoom start together (Creative Director).
	knockout_began.emit(match_over, player_won_round)

	# The result overlay waits out the death beat (wall-clock, dilation-immune).
	var timer: SceneTreeTimer = get_tree().create_timer(death_sequence_seconds, true, false, true)
	timer.timeout.connect(_finish_death_sequence.bind(match_over, player_won_round))


## Ends the death beat: resume normal speed, release the death cam, and NOW raise
## the post-round / post-game result overlay (and start the break clock).
func _finish_death_sequence(match_over: bool, player_won_round: bool) -> void:
	_in_death_sequence = false
	if _stack != null:
		_stack.resume_speed()
	else:
		Engine.time_scale = 1.0
	if _camera != null and _camera.has_method(&"end_death_cam"):
		_camera.end_death_cam()

	if match_over:
		match_ended.emit(player_score >= rounds_to_win)
		Sfx.play(&"victory" if player_score >= rounds_to_win else &"round_lose")
	else:
		_post_round_deadline_msec = Time.get_ticks_msec() + int(post_round_seconds * 1000.0)
		round_ended.emit(player_won_round, player_score, opponent_score, post_round_seconds)
		Sfx.play(&"round_win" if player_won_round else &"round_lose")


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


func _begin_round() -> void:
	round_number += 1
	_stack_entries.clear()
	_clear_projectiles()
	_clear_emerald()
	_reseed_emeralds()
	if _player != null and _player.has_method(&"reset_for_round"):
		_player.reset_for_round(0, SGFixed.from_float(player_spawn_y))
	if _opponent != null and _opponent.has_method(&"reset_for_round"):
		_opponent.reset_for_round(0, SGFixed.from_float(opponent_spawn_y))
	_set_sim_running(true)
	match_state = MatchState.ROUND_ACTIVE
	round_started.emit(round_number)


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
	# CLIENT VIEW (visual mirror): each player should see THEIR OWN wizard in the
	# near, well-lit foreground. The HOST owns Player (already near) — nothing to do.
	# The CLIENT owns Opponent (normally the FAR wizard), so MIRROR the visual court
	# front-to-back (VisualBridge.view_flip_z negates visual Z only — X kept so
	# left/right controls stay correct) — the client's wizard now renders at the
	# near baseline — and point the AUTHORED camera at it. This reuses all the
	# authored lighting/backdrop (no reverse-angle darkness); pure presentation, the
	# deterministic sim is identical on both peers.
	if not is_host:
		for vb in find_children("*", "VisualBridgeComponent", true, false):
			vb.view_flip_z = true
		if _camera != null and _camera.has_method(&"set_follow_target") and _opponent != null:
			_camera.set_follow_target(_opponent.get_node_or_null(^"WizardRig") as Node3D)
	var mine: String = "Player (blue, near)" if (_player != null and _player.is_multiplayer_authority()) else "Opponent (red, far)"
	print("[NETPLAY] peer uid=%d (host=%s) controls the %s wizard" % [my_id, str(is_host), mine])
	# Kick the deterministic handshake.
	nm.notify_scene_loaded()


func _clear_projectiles() -> void:
	if _projectiles == null:
		return
	for child in _projectiles.get_children():
		child.queue_free()


# =====================================================================
# Helpers
# =====================================================================

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
