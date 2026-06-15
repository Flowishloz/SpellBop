## stack_resolver.gd — Deterministic, rollback-safe authority for THE STACK window.
##
## THE STACK, SIM SIDE (Sprint 22 Phase 2): the wall-clock `TheStack` autoload now
## drives ONLY presentation (the slow-mo dilation + the on-screen countdown). The
## moment spells actually RESOLVE — and the stack-winner reward — must land on the
## SAME sim tick on both peers for rollback netcode, so THIS network_sync node owns
## it: a tick countdown, armed when the first spell stages, that releases every
## staged spell at tick 0 and then banks the last responder's +50% next-throw boost.
## All sim state is plain ints (rollback-serialization safe).
##
## WHY A SEPARATE NODE (not TheStack): TheStack is an autoload whose wall-clock state
## is NOT rolled back; folding the deterministic countdown into it would desync. This
## node lives in the arena scene, joins "network_sync" in netplay (SyncManager drives
## its _network_process) via set_netplay(), and self-drives via
## local_tick_driver_enabled in single-player — the exact pattern the wizards use.
##
## WHY THE COUNTER IS THE GUARD: `_resolve_ticks` reaching 0 IS the "resolve exactly
## once" guard. It is saved/loaded, so a rollback that lands AFTER resolution restores
## it at 0 (no re-fire) and one that lands BEFORE restores it > 0 (re-fires at the same
## tick). No separate un-saved boolean — that would be a rollback hole.
class_name StackResolver
extends Node

## The stack just resolved (all staged spells fired THIS tick). [param winner_side] is
## 0 none / 1 player-side / 2 opponent-side. MatchController listens to close the
## presentation window + announce the winner — GUARDED against rollback re-sims.
signal resolved(winner_side: int)

## When false, the local tick driver idles (the rollback SyncManager drives instead).
@export var local_tick_driver_enabled: bool = true

# --- Authoritative simulation state (ints only — rollback-safe) ---
var _resolve_ticks: int = 0    # countdown to resolution; > 0 = window OPEN
var _window_ticks: int = 0     # the N it was armed with (the fraction denominator)
var _last_stager: int = 0      # 0 none / 1 player-side / 2 opponent-side (winner = last responder)

# --- Non-sim wiring (stable scene refs set by MatchController.setup() — they never
# change across a match, so they are identical on both peers and safe to hold). ---
var _casters: Array = []
var _player: Node = null
var _opponent: Node = null
var _winner_boost_fp: int = 65536


## MatchController hands us the stable scene refs in its _ready (NOT sim state).
func setup(casters: Array, player: Node, opponent: Node, winner_boost_fp: int) -> void:
	_casters = casters
	_player = player
	_opponent = opponent
	_winner_boost_fp = winner_boost_fp


## NETPLAY HANDOFF (mirrors PlayerController.set_netplay): stop self-driving and join
## the group SyncManager scans at start(). Called from MatchController._enter_netplay,
## BEFORE the handshake completes — a scene-authored node can't rely on the spawn-time
## `SyncManager.started` check the projectiles use.
func set_netplay() -> void:
	local_tick_driver_enabled = false
	add_to_group(&"network_sync")


## Open the window for [param window_ticks] sim ticks — called from a caster's tick the
## instant the FIRST spell stages. IDEMPOTENT: a stage onto an already-open window does
## NOT re-arm (the shared-clock rule), so everything resolves together.
func arm(window_ticks: int) -> void:
	if _resolve_ticks == 0:
		_resolve_ticks = maxi(1, window_ticks)
		_window_ticks = _resolve_ticks


## A caster placed a spell on the stack — record its SIDE so the LAST responder (newest
## spell) wins. Called from the caster's tick.
func notify_staged(side: int) -> void:
	_last_stager = side


## True while a stack window is open — the counter reactive-lock reads this (a
## deterministic, rolled-back sim read, replacing TheStack's wall clock).
func is_window_open() -> bool:
	return _resolve_ticks > 0


## Window remaining as 0..ONE fixed-point (the counter WOA reads this: later in the
## countdown = lower fraction = stronger counter). Pure int sim state.
func window_fraction_fp() -> int:
	if _resolve_ticks <= 0 or _window_ticks <= 0:
		return 0
	return SGFixed.div(SGFixed.from_int(_resolve_ticks), SGFixed.from_int(_window_ticks))


## Drop an open window WITHOUT resolving (a KO / round reset ends the round before
## release). Called from MatchController (in-tick on KO, or round flow).
func cancel() -> void:
	_resolve_ticks = 0
	_last_stager = 0


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

func _network_process(_input: Dictionary) -> void:
	if _resolve_ticks <= 0:
		return
	_resolve_ticks -= 1
	if _resolve_ticks == 0:
		_resolve()


## RESOLUTION — the one deterministic beat: every staged spell fires THIS tick, then
## the last responder banks the +50% boost. The last responder's caster releases FIRST
## (global LIFO: a counter looses just before the spell it answered); within a caster,
## release_staged() pops newest-first. Both casters fire the same tick, so this only
## orders same-tick spawns — deterministic on both peers. The boost is granted AFTER all
## releases, so it lands on the winner's NEXT throw (matches the old _award_stack_winner).
func _resolve() -> void:
	for caster in _ordered_casters():
		if caster != null and is_instance_valid(caster):
			while caster.is_staging():
				caster.release_staged()
	var winner_side: int = _last_stager
	var winner: Node = _player if winner_side == 1 else (_opponent if winner_side == 2 else null)
	if winner != null and is_instance_valid(winner) and winner.has_method(&"grant_speed_boost"):
		winner.grant_speed_boost(_winner_boost_fp)
	_last_stager = 0
	resolved.emit(winner_side)


## Casters with the last responder's side first (the rest follow in scene order).
func _ordered_casters() -> Array:
	if _last_stager == 0:
		return _casters
	var first: Array = []
	var rest: Array = []
	for caster in _casters:
		if caster != null and is_instance_valid(caster) \
				and (1 if int(caster.cast_direction_y) < 0 else 2) == _last_stager:
			first.append(caster)
		else:
			rest.append(caster)
	first.append_array(rest)
	return first


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in netplay.
func _physics_process(_delta: float) -> void:
	if local_tick_driver_enabled:
		_network_process({})


func _save_state() -> Dictionary:
	return {
		"rt": _resolve_ticks,
		"wt": _window_ticks,
		"ls": _last_stager,
	}


func _load_state(state: Dictionary) -> void:
	_resolve_ticks = int(state.get("rt", 0))
	_window_ticks = int(state.get("wt", 0))
	_last_stager = int(state.get("ls", 0))
