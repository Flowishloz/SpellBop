## player_controller.gd — Thin coordinator for the player's component stack.
##
## LOCAL TICK DRIVER — this _physics_process loop is replaced by the rollback
## SyncManager in a later sprint. Nothing in here should grow gameplay logic;
## it only (1) advances the local tick counter, (2) captures + buffers input,
## and (3) hands the tick's input to the deterministic MovementComponent.
##
## All gameplay math is fixed-point (SG Physics 2D). This node IS the
## deterministic body (SGCharacterBody2D); its components do the work:
##   - InputBufferComponent:  tick -> input ring buffer (prediction baseline).
##   - MovementComponent:     deterministic X-axis mover (fixed-point).
##   - SpellCasterComponent:  deterministic cast cooldown + projectile spawner.
##   - VisualBridgeComponent: maps sim X/Y -> visual X/Z (reads sim, never writes).
##
## GENERIC TICK DRIVING: every child that has_method("_network_process") is
## simulated each tick, in SCENE-TREE CHILD ORDER — child order is part of the
## deterministic contract, so it must be identical on every peer. CHILD ORDER
## MATTERS: keep MovementComponent EARLIEST among simulated children so
## everything downstream (e.g. SpellCasterComponent spawning at the caster's
## position) sees this tick's post-move state. Likewise every child that
## has_method("_save_state") is aggregated into this node's state snapshot,
## keyed by its (unique-per-parent) child node name.
##
## Recommended scene shape (built by the Creative Director in the editor):
##   PlayerController (SGCharacterBody2D) [+ SGCollisionShape2D]
##     ├─ InputBufferComponent
##     ├─ MovementComponent       (FIRST simulated child — order matters)
##     ├─ SpellCasterComponent
##     └─ VisualBridgeComponent  (visual_root -> the wizard's Node3D rig)
class_name PlayerController
extends SGCharacterBody2D

## Path to the InputBufferComponent child. Leave empty to auto-find by class.
@export var input_buffer_path: NodePath

## Path to the MovementComponent child. Leave empty to auto-find by class.
@export var movement_path: NodePath

## When false, the local tick driver idles (useful for menus/cutscenes, and
## flipped off permanently once the rollback SyncManager takes over driving).
@export var local_tick_driver_enabled: bool = true

## Current simulation tick (int). Owned by the local driver for now; the
## rollback framework will own tick counting later.
var current_tick: int = 0

var _input_buffer: InputBufferComponent
var _movement: MovementComponent

# Optional AI input source. When an AIBrainComponent child exists, this
# controller is an AI wizard: _get_local_input() asks the brain instead of
# polling the keyboard. Identical buffer -> movement -> caster pipeline either
# way — in netplay, AI inputs sync and roll back exactly like human inputs.
var _ai_brain: AIBrainComponent

# Optional HealthComponent child (resolved in _ready). Projectile hit scans
# reach this wizard through apply_damage() below.
var _health: HealthComponent

# Children driven each tick (have _network_process), in scene-tree child order —
# that order is deterministic and identical on every peer. Built once in _ready().
var _simulated_components: Array[Node] = []

# Children captured in _save_state()/_load_state() (have _save_state), keyed by
# child node name in the aggregate snapshot. Built once in _ready().
var _stateful_components: Array[Node] = []

# RENDER-RATE PRESS LATCH (Creative Director slow-mo fix): inside the Stack
# window the sim ticks ~6x/second, so a quick card TAP can fall entirely
# between two ticks and be lost. _process polls press EDGES at render rate
# and latches them; the next tick's input consumes the latch. Local input
# collection only — the per-tick input dicts stay the deterministic artifact.
var _card_press_latched: int = 0

# STACK WINNER REWARD (Phase 1): a one-shot launch-speed multiplier (fixed-point,
# ONE = no boost) granted to this wizard when it wins a stack; the next
# projectile it fires multiplies its speed by this, then clears it. Saved as sim
# state so it survives a rollback re-sim.
var _pending_speed_boost_fp: int = SGFixed.ONE

# NETPLAY (Sprint 21): when true, the rollback SyncManager drives this wizard
# instead of the local _physics_process tick driver. Input ownership is gated by
# multiplayer authority. _netplay_casting is false this sprint (projectile spawns
# aren't rollback-routed yet) — movement syncs, casting is suppressed.
var _netplay: bool = false
var _netplay_casting: bool = false
# Two-windows-on-ONE-machine dev opt-in (pass `-- --local-split`): drives the HOST
# instance with A/D and the CLIENT with the arrow keys, so a single keyboard controls
# both wizards unambiguously. OFF by default so a real online / mobile peer (one per
# device) reads the DEFAULT move_left/move_right actions — which the TOUCH joystick,
# A/D, AND the arrows all feed — otherwise touch movement produces no input online.
var _local_split: bool = false

# ONLINE REMATCH (Sub-phase 3 follow-up): a render-rate latch set by the Play Again
# button / cast shortcut at match-over (latch_rematch), injected into this wizard's
# SYNCED input for ONE tick so both peers see it on the SAME rolled-back tick.
# _rematch_requested is that tick's derived flag (saved/rolled-back) — the
# RoundFlowResolver polls it in its OVER phase and resets the match deterministically.
# Netplay only (offline rematch resets directly via MatchController.request_rematch).
var _rematch_latched: bool = false
var _rematch_requested: bool = false


func _ready() -> void:
	# HARDCODED COLLISION LAYERS (Sprint 2 hotfix) — the editor UI fails to
	# persist SG Physics 2D layer assignments, leaving bodies on the plugin
	# default (layer 1 / mask 1). DO NOT move this back to the Inspector.
	# See scripts/physics_layers.gd. The player lives on the player layer and
	# collides with walls only — NOT with projectiles (projectile->player hits
	# become an Area-based damage system in a later sprint, not body collision).
	collision_layer = PhysicsLayers.LAYER_PLAYERS
	collision_mask = PhysicsLayers.LAYER_WALLS

	# ROTATION LOCK (Sprint 2 hotfix round 3) — the deterministic body is
	# PERMANENTLY rotation-locked. Character facing is visual-only, done on the
	# 3D rig by the VisualBridge — never rotate or mirror the SG body or any SG
	# ancestor. NOTE (ClassDB-verified, and proven by headless probe): the SG
	# float and fixed transforms are SEPARATE — writing the float `rotation`
	# (editor gizmo, Node2D API) NEVER reaches `fixed_rotation`, and only
	# `fixed_rotation` exists in the sim. This hardcoded zero guards against any
	# editor-persisted fixed rotation sneaking into the deterministic state.
	fixed_rotation = 0

	# Register as a hit-scannable wizard (HitDetectionComponent queries this
	# group with deterministic int math — no physics mask involvement).
	add_to_group(&"wizards")

	if not input_buffer_path.is_empty():
		_input_buffer = get_node_or_null(input_buffer_path) as InputBufferComponent
	if not movement_path.is_empty():
		_movement = get_node_or_null(movement_path) as MovementComponent
	for child in get_children():
		if _input_buffer == null and child is InputBufferComponent:
			_input_buffer = child
		elif _movement == null and child is MovementComponent:
			_movement = child
		elif _ai_brain == null and child is AIBrainComponent:
			_ai_brain = child
		elif _health == null and child is HealthComponent:
			_health = child
	assert(_input_buffer != null, "PlayerController: missing InputBufferComponent child.")
	assert(_movement != null, "PlayerController: missing MovementComponent child.")

	# Collect every rollback-contract child in scene-tree child order (CHILD
	# ORDER MATTERS — see header; keep MovementComponent earliest).
	_simulated_components.clear()
	_stateful_components.clear()
	for child in get_children():
		if child.has_method("_network_process"):
			_simulated_components.append(child)
		if child.has_method("_save_state"):
			_stateful_components.append(child)


## Render-rate edge collector (see the latch note above). Keyboard only —
## the AI brain produces its own inputs.
func _process(_delta: float) -> void:
	if _ai_brain != null or not local_tick_driver_enabled:
		return
	for slot in [1, 2, 3]:
		var action: String = "card_slot_%d" % slot
		if InputMap.has_action(action) and Input.is_action_just_pressed(action):
			_card_press_latched = slot


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in a later sprint.
func _physics_process(_delta: float) -> void:
	if not local_tick_driver_enabled:
		return

	current_tick += 1

	# Capture this tick's local input and buffer it (the buffer also serves
	# rollback re-simulation later, when ticks get replayed).
	var captured: Dictionary = _get_local_input()
	_input_buffer.store(current_tick, captured)

	# Always simulate from the buffer, not the raw capture — identical code
	# path to what rollback re-simulation will use.
	var tick_input: Dictionary = _input_buffer.get_input(current_tick)
	for component in _simulated_components:
		component._network_process(tick_input)


# =====================================================================
# ROLLBACK CONTRACT (called locally for now, by SyncManager later)
# =====================================================================

## Routes projectile damage to the HealthComponent (the wizard's public
## damage API — hit scans never poke component internals directly).
func apply_damage(amount: int, element: int = 0) -> void:
	if _health != null:
		_health.apply_damage(amount, element)


## Routes a heal (the healing-emerald pickup) to the HealthComponent — same
## public-API rule as apply_damage.
func apply_heal(amount: int) -> void:
	if _health != null:
		_health.apply_heal(amount)


## True while this wizard is below max health (a healing emerald would actually
## grant a life). The emerald reads this to fire the "earned the heart" pop cue
## only on a REAL gain, never on a wasted full-health pickup. Presentation read —
## pure query, no sim mutation.
func is_hurt() -> bool:
	return _health != null and _health.get_health() < _health.max_health


## Routes a timed movement slow (the Counter's frost) to MovementComponent —
## same public-API rule as apply_damage.
func apply_slow(duration_ticks: int, scale_fp: int) -> void:
	if _movement != null:
		_movement.apply_timed_slow(duration_ticks, scale_fp)


## SHIELD-CAPTURE MOTION LOCK (Task 3): a barrier this wizard deployed re-pushes this every held tick
## while it grips a captured ball, freezing the owner in place for the hold. Same public-API routing as
## apply_slow — the barrier never pokes the MovementComponent directly.
func freeze_movement(ttl: int = 2) -> void:
	if _movement != null:
		_movement.apply_movement_freeze(ttl)


## SHIELD-RALLY CARD LOCK: a capturing BarrierController calls this on BOTH wizards every rally hold tick to
## lock their deck cards (gates CASTING only, never movement — so the non-blocking wizard keeps dodging).
## Same public-API routing as freeze_movement; the barrier never pokes the MovementComponent directly.
func apply_card_lock(ttl: int = 2) -> void:
	if _movement != null:
		_movement.apply_card_lock(ttl)


## STACK WINNER REWARD: grant this wizard a one-shot launch-speed multiplier for
## its NEXT fired projectile (MatchController calls this when it wins a stack).
func grant_speed_boost(multiplier_fp: int) -> void:
	_pending_speed_boost_fp = maxi(SGFixed.ONE, multiplier_fp)


## Returns and CLEARS the pending one-shot speed boost (ONE = none). A caster
## calls this as it launches so the reward lands on exactly one throw.
func consume_speed_boost() -> int:
	var boost: int = _pending_speed_boost_fp
	_pending_speed_boost_fp = SGFixed.ONE
	return boost


## ONLINE REMATCH: latch a play-again request (MatchController.request_rematch calls this
## on the LOCAL wizard at match-over). Consumed into the next synced input tick — see
## _get_local_input — so the RoundFlowResolver resets the match on the agreed tick.
func latch_rematch() -> void:
	_rematch_latched = true


## True if this wizard's CURRENT tick requested a rematch (the RoundFlowResolver polls
## this in its OVER phase). Derived from the synced input + saved, so it rolls back and
## the reset lands on the same tick on both peers.
func wants_rematch() -> bool:
	return _rematch_requested


## ROUND RESET (called by MatchController between rounds): teleport back to
## the spawn point, kill all motion/debuffs, refill health. The fixed write
## is a teleport, so sync_to_physics_engine() is mandatory.
func reset_for_round(spawn_x_fp: int, spawn_y_fp: int) -> void:
	set_global_fixed_position(SGFixed.vector2(spawn_x_fp, spawn_y_fp))
	sync_to_physics_engine()
	if _movement != null:
		_movement.halt()
	if _health != null:
		_health.reset()
	_pending_speed_boost_fp = SGFixed.ONE  # stack-winner reward doesn't carry rounds
	# Drop any in-flight channels / staged spells / cooldowns (duck-typed so
	# both caster classes — and future ones — reset without name coupling).
	for child in get_children():
		if child.has_method(&"reset_cast_state"):
			child.reset_cast_state()


## NETPLAY HANDOFF (Sprint 21): give this wizard to the rollback SyncManager.
## [param owner_peer_id] is the peer that controls it (host owns Player, client
## owns Opponent — computed identically on both peers). Stops the local tick
## driver (SyncManager drives ticks now), claims multiplayer authority so input
## is attributed to the owning peer, and joins the "network_sync" group that
## SyncManager scans at start(). [param casting_enabled] is false this sprint —
## projectile spawns aren't rollback-routed yet, so movement syncs but casting
## is suppressed.
func set_netplay(owner_peer_id: int, casting_enabled: bool) -> void:
	_netplay = true
	_netplay_casting = casting_enabled
	_local_split = OS.get_cmdline_user_args().has("--local-split")
	local_tick_driver_enabled = false
	set_multiplayer_authority(owner_peer_id)
	add_to_group(&"network_sync")


## Produces this tick's input as a compact int-only Dictionary: the AI brain
## when one is attached, otherwise the local keyboard. Both sources speak the
## same InputCommand shape, so everything downstream is source-agnostic.
func _get_local_input() -> Dictionary:
	if _netplay:
		# Only the OWNING peer supplies this wizard's input; the other peer's
		# input arrives over the network (attributed by authority + node path).
		if not is_multiplayer_authority():
			return {}
		# SEPARATE devices (the real online / mobile case — one peer per device): BOTH
		# peers read the DEFAULT move_left/move_right, which the touch joystick AND A/D AND
		# the arrow keys all feed, so touch movement works online. The per-role A/D-vs-arrows
		# split is ONLY meaningful for TWO windows on ONE machine (one keyboard) and is
		# opt-in via --local-split — otherwise it would strand touch / separate-device
		# movement (the joystick presses the DEFAULT actions, which the split doesn't read).
		var actions: Dictionary = InputCommand.DEFAULT_ACTIONS
		if _local_split:
			actions = InputCommand.HOST_ACTIONS if multiplayer.is_server() else InputCommand.CLIENT_ACTIONS
		var inp: Dictionary = InputCommand.capture_local(actions)
		if _card_press_latched != 0:
			if not inp.has(InputCommand.KEY_CARD):
				inp[InputCommand.KEY_CARD] = _card_press_latched
			_card_press_latched = 0
		# Play-again request (match-over): inject for ONE tick so both peers see it on the
		# same rolled-back tick and the RoundFlowResolver's OVER-phase poll resets together.
		if _rematch_latched:
			inp[InputCommand.KEY_REMATCH] = 1
			_rematch_latched = false
		# Base fireball spawns are rollback-routed (Sprint 22), so KEY_CAST stays — both
		# peers charge + fire deterministically. CARD spawns are now rollback-routed too
		# (Phase 2b: SyncManager.spawn) and resolve on a deterministic tick (Phase 2a:
		# StackResolver), so cards are enabled in netplay once _netplay_casting is set.
		if not _netplay_casting:
			inp.erase(InputCommand.KEY_CARD)
		return inp
	if _ai_brain != null:
		return _ai_brain.decide(current_tick)
	var captured: Dictionary = InputCommand.capture_local()
	# Merge render-rate latched taps (consumed exactly once) so presses that
	# fell between slow-mo ticks still land on the very next tick.
	if _card_press_latched != 0:
		if not captured.has(InputCommand.KEY_CARD):
			captured[InputCommand.KEY_CARD] = _card_press_latched
		_card_press_latched = 0
	return captured


## Advances all simulated components by one tick, in scene-tree child order
## (deterministic — MovementComponent first by convention). Mirrors the
## contract the rollback framework calls on network-synced nodes.
func _network_process(input: Dictionary) -> void:
	# Derive the rematch flag from THIS tick's synced input (RoundFlowResolver polls it via
	# wants_rematch()). Set before the components tick so a same-tick read is current.
	_rematch_requested = InputCommand.get_rematch(input) != 0
	for component in _simulated_components:
		component._network_process(input)


## Aggregates component states keyed by child node name, plus the tick counter.
## Leaf values are ints only (fixed-point) — rollback-serialization safe.
## (Don't name a component child "tick" — that key is reserved here.)
func _save_state() -> Dictionary:
	var state: Dictionary = {
		"tick": current_tick,
		"psb": _pending_speed_boost_fp,
		"rmt": 1 if _rematch_requested else 0,
	}
	for component in _stateful_components:
		state[String(component.name)] = component._save_state()
	return state


## Restores an aggregate snapshot produced by _save_state(), matching component
## sub-states back by child node name.
func _load_state(state: Dictionary) -> void:
	current_tick = int(state.get("tick", current_tick))
	_pending_speed_boost_fp = int(state.get("psb", SGFixed.ONE))
	_rematch_requested = int(state.get("rmt", 0)) != 0
	for component in _stateful_components:
		var key: String = String(component.name)
		if state.has(key):
			component._load_state(state[key])
