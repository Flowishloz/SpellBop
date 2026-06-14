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
@export var capture_release_trauma: float = 0.55

## Sustained rumble per fireball charge level (index = level 0-3). Escalates
## hard so each banked gauge visibly grips the screen more (Creative Director).
@export var charge_rumble_levels: Array[float] = [0.06, 0.22, 0.4, 0.62]

## Extra one-shot trauma KICK the instant a new gauge banks, scaled by the gauge
## number (gauge 1 = 1x, 2 = 2x, 3 = 3x of this) — a sharp "pop" per fill.
@export var charge_pop_trauma: float = 0.1

var match_state: MatchState = MatchState.ROUND_ACTIVE
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

	# Dash SFX for both wizards (presentation).
	for movement in find_children("*", "MovementComponent", true, false):
		movement.dashed.connect(func() -> void: Sfx.play(&"dash"))

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

	round_started.emit(round_number)
	_warm_up_render_pipelines()


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


func _process(_delta: float) -> void:
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
	_begin_round()


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


## The countdown expired: resolve the stack LIFO — the newest slap (the
## counter) releases first, then the spell it answered. NETPLAY NOTE: the
## release originates from the wall-clock window today; it becomes a
## tick-counted event with the rollback sprint.
func _on_stack_closed() -> void:
	_window_open_flag = false
	if match_state != MatchState.ROUND_ACTIVE:
		_stack_entries.clear()
		return
	var entries: Array[Node] = _stack_entries.duplicate()
	_stack_entries.clear()
	for i in range(entries.size() - 1, -1, -1):
		if is_instance_valid(entries[i]) and entries[i].has_method(&"release_staged"):
			entries[i].release_staged()


## An effect actually resolved (projectile fired / barrier deployed / wave
## loosed): impact feedback + barrier WOA wiring. Instant defense/counter
## casts do NOT open the Stack — only staged attacks telegraph.
func _on_spell_cast(projectile: Node, spell: SpellResource) -> void:
	if _camera != null:
		var trauma: float = card_cast_trauma if (spell != null and spell.is_card) else cast_trauma
		if spell is CardResource:
			trauma += spell.screen_shake_intensity
		_camera.add_trauma(trauma)
	# A deployed barrier's capture drama: rumble builds during the hold
	# (Lethal-Company anticipation), slam on release.
	if projectile != null and projectile.has_signal(&"capture_charging"):
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


func _on_capture_charging(progress: float) -> void:
	if _camera != null:
		_camera.set_rumble(lerpf(0.15, 0.55, clampf(progress, 0.0, 1.0)))


func _on_capture_released() -> void:
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

	# State changes BEFORE close_window(): _on_stack_closed must see the
	# round as over so a KO never releases staged spells into the break.
	if player_score >= rounds_to_win or opponent_score >= rounds_to_win:
		match_state = MatchState.MATCH_OVER
	else:
		match_state = MatchState.POST_ROUND

	if _stack != null:
		_stack.close_window()
	if _camera != null:
		_camera.set_rumble(0.0)
		_camera.add_trauma(0.7)

	if match_state == MatchState.MATCH_OVER:
		match_ended.emit(player_score >= rounds_to_win)
		Sfx.play(&"victory" if player_score >= rounds_to_win else &"round_lose")
	else:
		_post_round_deadline_msec = Time.get_ticks_msec() + int(post_round_seconds * 1000.0)
		round_ended.emit(player_won_round, player_score, opponent_score, post_round_seconds)
		Sfx.play(&"round_win" if player_won_round else &"round_lose")


func _begin_round() -> void:
	round_number += 1
	_stack_entries.clear()
	_clear_projectiles()
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
	for wizard in [_player, _opponent]:
		if wizard != null and "local_tick_driver_enabled" in wizard:
			wizard.local_tick_driver_enabled = running


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
