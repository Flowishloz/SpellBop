## round_flow_resolver.gd — Deterministic, rollback-safe authority for ROUND FLOW.
##
## THE BLOCKER IT SOLVES (Sprint 22 Sub-phase 3): KO detection was already
## deterministic (HP→0 on a sim tick), but the death-sequence timer (a
## SceneTreeTimer) and the post-round break (Time.get_ticks_msec) were WALL-CLOCK,
## and _begin_round() mutated SIM state OFF-TICK from a non-rollback node
## (reposition wizards, health reset, clear projectiles, round number) — so the
## FIRST online KO desyncs. It is also the ROOT CAUSE the ae325f4 crash-guards
## only paper over: a wall-clock _clear_projectiles() landing mid-tick is exactly
## what drives a detached entity into the null-get_tree() crash.
##
## THE FIX (mirrors StackResolver verbatim): this network_sync node OWNS the round
## beats as plain-int sim state. Each tick it DETECTS the KO by POLLING HP, holds
## the phase + countdown + scores + round number as rolled-back ints, and PERFORMS
## the reset (reposition, health reset, clear projectiles, increment round) on a
## DETERMINISTIC countdown-zero tick that lands on the SAME tick on both peers.
## MatchController's wall-clock death/break cinematics are demoted to PRESENTATION,
## triggered off this node's phase-change signals and guarded by is_in_rollback()
## (the exact _on_resolver_resolved pattern TheStack became in Phase 2a).
##
## WHY POLL, NOT THE knocked_out SIGNAL: HealthComponent.knocked_out fires inside
## apply_damage on the 5→0 transition. On a rollback the lethal damage is reverted
## and RE-APPLIED on the re-sim, RE-FIRING knocked_out — double-counting the round
## and the score. Polling get_health() each tick and gating on the ACTIVE phase
## makes "the round ends" a once-per-phase sim transition that rolls back cleanly:
## the phase int IS the "resolve exactly once" guard (like StackResolver's
## _resolve_ticks==0). It is saved/loaded, so a rollback landing AFTER the KO
## restores DEATH_WAIT (no re-count) and one landing BEFORE restores ACTIVE
## (re-detects the KO on the same tick).
##
## WHY THE TICK COUNTS ARE REAL-TIME-CORRECT UNDER SLOW-MO: sim ticks advance at
## the fixed tick_rate REGARDLESS of the death slow-mo — Engine.time_scale scales
## each tick's DELTA (motion looks slow) but NOT how often _physics_process fires
## (the same property that lets StackResolver count seconds × tick_rate). So
## death_seconds × tick_rate ticks span death_seconds of REAL time, matching the
## old ignore_time_scale SceneTreeTimer.
class_name RoundFlowResolver
extends Node

## ACTIVE→DEATH_WAIT: a KO landed. [param player_won_round] = the Player (blue, side
## 1) won; [param match_over] = this KO took the match. MatchController starts the
## death cinematics (slow-mo + death cam + verdict) — GUARDED against rollback re-sims.
signal ko_began(player_won_round: bool, match_over: bool)
## DEATH_WAIT→POST_ROUND: the death beat ended; the inter-round break begins.
signal break_began(player_won_round: bool, player_score: int, opponent_score: int)
## DEATH_WAIT→OVER: the death beat ended on a match-ending KO; the result screen raises.
signal match_concluded(player_won_match: bool)
## POST_ROUND→ACTIVE: the break elapsed and the round was reset IN-TICK; round visuals pop.
signal round_reset(new_round_number: int)

enum Phase { ACTIVE, DEATH_WAIT, POST_ROUND, OVER }

## When false, the local tick driver idles (the rollback SyncManager drives instead).
@export var local_tick_driver_enabled: bool = true

# --- Authoritative simulation state (ints only — rollback-serialization safe) ---
var _phase: int = Phase.ACTIVE
var _countdown: int = 0      # ticks remaining in DEATH_WAIT / POST_ROUND (0 in ACTIVE / OVER)
var _player_score: int = 0
var _opponent_score: int = 0
var _round_number: int = 1
var _winner: int = 0         # last round's winner: 0 none / 1 player / 2 opponent

# Emerald spawn cadence (Phase 3): the LCG + countdown + per-match count, ALL saved sim
# state, so the spawn TICK lands identically on both peers (it was a wall-clock,
# netplay-disabled MatchController._physics_process before).
var _em_rng: int = 0
var _em_cd: int = 0          # ticks to the next emerald (<= 0 = spawn this tick)
var _em_cnt: int = 0         # emeralds spawned this match (capped at _em_max_per_match)

# --- Non-sim wiring (stable scene refs from MatchController.setup() — identical on
# both peers, never change across a match, so safe to hold un-serialized). ---
var _player: Node = null
var _opponent: Node = null
var _player_health: Node = null
var _opponent_health: Node = null
var _projectiles: Node = null
var _stack_resolver: Node = null
var _death_ticks: int = 1
var _break_ticks: int = 1
var _rounds_to_win: int = 2
var _player_spawn_fp: int = 0
var _opponent_spawn_fp: int = 0

# --- Emerald cadence config (from setup_emerald; the actual SyncManager.spawn is a HOOK
# into MatchController so this node never references SyncManager). ---
var _em_enabled: bool = false
var _em_min_ticks: int = 1
var _em_span_ticks: int = 1
var _em_max_per_match: int = 2
var _em_base_seed: int = 0
var _em_spawn_hook: Callable = Callable()


## MatchController hands us the stable scene refs + round tuning in its _ready (NOT sim
## state). death_seconds / break_seconds convert to ticks HERE (× tick_rate) the same
## way the StackResolver window does, so Director/test tuning of the seconds still
## drives the deterministic sim countdown.
func setup(player: Node, opponent: Node, player_health: Node, opponent_health: Node,
		projectiles: Node, stack_resolver: Node, death_seconds: float, break_seconds: float,
		rounds_to_win: int, player_spawn_fp: int, opponent_spawn_fp: int, tick_rate: int = 60) -> void:
	_player = player
	_opponent = opponent
	_player_health = player_health
	_opponent_health = opponent_health
	_projectiles = projectiles
	_stack_resolver = stack_resolver
	var safe_tr: int = maxi(1, tick_rate)
	_death_ticks = maxi(1, ceili(death_seconds * float(safe_tr)))
	_break_ticks = maxi(1, ceili(break_seconds * float(safe_tr)))
	_rounds_to_win = maxi(1, rounds_to_win)
	_player_spawn_fp = player_spawn_fp
	_opponent_spawn_fp = opponent_spawn_fp


## MatchController wires the emerald spawn cadence (Phase 3). The spawn itself is a HOOK
## (spawn_hook.call(ox, oy, seed) -> bool, ox/oy = sim-unit offsets from centre) so this
## node never references SyncManager; enabled=false leaves the cadence dormant.
func setup_emerald(enabled: bool, min_ticks: int, span_ticks: int, max_per_match: int,
		base_seed: int, spawn_hook: Callable) -> void:
	_em_enabled = enabled
	_em_min_ticks = maxi(1, min_ticks)
	_em_span_ticks = maxi(1, span_ticks)
	_em_max_per_match = maxi(0, max_per_match)
	_em_base_seed = base_seed
	_em_spawn_hook = spawn_hook
	_reseed_emeralds()


## NETPLAY HANDOFF (mirrors StackResolver.set_netplay / PlayerController.set_netplay):
## stop self-driving and join the group SyncManager scans at start(). Called from
## MatchController._enter_netplay BEFORE the handshake — a scene-authored node can't
## rely on the spawn-time SyncManager.started check the projectiles use.
func set_netplay() -> void:
	local_tick_driver_enabled = false
	add_to_group(&"network_sync")


# --- Authoritative reads for MatchController's UI mirror (always the rolled-back
# truth, so the mirror never drifts on a mispredicted-then-rolled-back KO). ---
func get_player_score() -> int: return _player_score
func get_opponent_score() -> int: return _opponent_score
func get_round_number() -> int: return _round_number
func get_phase() -> int: return _phase
func get_emerald_countdown() -> int: return _em_cd      # ticks to next emerald (smoke fingerprint)
func get_emerald_count() -> int: return _em_cnt          # emeralds spawned this match


## REMATCH — a fresh scoreboard from MATCH_OVER. Called OFF-TICK by MatchController for an
## OFFLINE rematch, and IN-TICK from the OVER-phase poll for an ONLINE rematch (the
## play-again request rides the synced input, so both peers reset on the SAME tick). Emits
## round_reset(1) so MatchController runs the presentation reset for BOTH paths (hide the
## result screen, reset stats + emerald budget, pop ROUND 1).
func reset_match() -> void:
	_phase = Phase.ACTIVE
	_countdown = 0
	_player_score = 0
	_opponent_score = 0
	_round_number = 1
	_winner = 0
	_clear_projectiles()
	_clear_emeralds()
	_reset_wizards()
	_em_cnt = 0          # a fresh match refills the emerald budget
	_reseed_emeralds()
	round_reset.emit(_round_number)


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

func _network_process(_input: Dictionary) -> void:
	match _phase:
		Phase.ACTIVE:
			_poll_ko()
			if _phase == Phase.ACTIVE:   # no KO this tick — run the emerald cadence
				_tick_emerald()
		Phase.DEATH_WAIT:
			_countdown -= 1
			if _countdown <= 0:
				_end_death_wait()
		Phase.POST_ROUND:
			_countdown -= 1
			if _countdown <= 0:
				_do_reset()
		Phase.OVER:
			# A play-again request rides the synced input (PlayerController.wants_rematch),
			# so it lands on the SAME tick on both peers — reset the whole match in-tick.
			if _wants_rematch(_player) or _wants_rematch(_opponent):
				reset_match()


## Detect the round-ending KO by polling HP (see header for why not the signal).
## Opponent-down is checked FIRST, so a same-tick MUTUAL KO (rare — a simultaneous
## stack resolution that kills both) deterministically credits the Player; both
## peers apply the identical rule, so it can never desync.
func _poll_ko() -> void:
	var o_hp: int = _opponent_health.get_health() if (_opponent_health != null and is_instance_valid(_opponent_health)) else 1
	var p_hp: int = _player_health.get_health() if (_player_health != null and is_instance_valid(_player_health)) else 1
	var player_won: bool
	if o_hp <= 0:
		player_won = true
	elif p_hp <= 0:
		player_won = false
	else:
		return
	_winner = 1 if player_won else 2
	if player_won:
		_player_score += 1
	else:
		_opponent_score += 1
	# Kill any open stack window IN-TICK so a staged spell can't resolve into a dead
	# round (replaces MatchController's old off-tick _resolver.cancel()).
	if _stack_resolver != null and is_instance_valid(_stack_resolver) and _stack_resolver.has_method(&"cancel"):
		_stack_resolver.cancel()
	var match_over: bool = _player_score >= _rounds_to_win or _opponent_score >= _rounds_to_win
	_phase = Phase.DEATH_WAIT
	_countdown = _death_ticks
	_clear_emeralds()   # no emerald lingers into the death beat
	ko_began.emit(player_won, match_over)


## The death beat elapsed: either the match is over, or the inter-round break opens.
func _end_death_wait() -> void:
	var match_over: bool = _player_score >= _rounds_to_win or _opponent_score >= _rounds_to_win
	if match_over:
		_phase = Phase.OVER
		_countdown = 0
		match_concluded.emit(_winner == 1)
	else:
		_phase = Phase.POST_ROUND
		_countdown = _break_ticks
		break_began.emit(_winner == 1, _player_score, _opponent_score)


## The break elapsed: reset the round IN-TICK (deterministic, rolled back) — clear
## projectiles (now an in-tick SyncManager.despawn, THE crash fix), reset both wizards
## (reposition + health refill + drop staged/cooldown state), bump the round number,
## and return to ACTIVE.
func _do_reset() -> void:
	_round_number += 1
	if _stack_resolver != null and is_instance_valid(_stack_resolver) and _stack_resolver.has_method(&"cancel"):
		_stack_resolver.cancel()
	_clear_projectiles()
	_clear_emeralds()
	_reset_wizards()
	_reseed_emeralds()   # fresh cadence (mixing the new round number) for the new round
	_winner = 0
	_phase = Phase.ACTIVE
	_countdown = 0
	round_reset.emit(_round_number)


func _reset_wizards() -> void:
	if _player != null and is_instance_valid(_player) and _player.has_method(&"reset_for_round"):
		_player.reset_for_round(0, _player_spawn_fp)
	if _opponent != null and is_instance_valid(_opponent) and _opponent.has_method(&"reset_for_round"):
		_opponent.reset_for_round(0, _opponent_spawn_fp)


## True if a wizard requested a play-again this tick (netplay; the wizard derives it from
## its synced input + saves it). Polled ONLY in OVER, so a stray request mid-match is ignored.
func _wants_rematch(wizard: Node) -> bool:
	return wizard != null and is_instance_valid(wizard) \
			and wizard.has_method(&"wants_rematch") and wizard.wants_rematch()


# =====================================================================
# Emerald spawn cadence (Phase 3)
# =====================================================================

## Run once per ACTIVE tick: one emerald at a time (live "pickups" count), at most
## _em_max_per_match across the match. The spawn lands on a deterministic tick, so both
## peers spawn the SAME emerald (same position + seed) on the SAME tick.
func _tick_emerald() -> void:
	if not _em_enabled or _em_cnt >= _em_max_per_match:
		return
	if _live_pickup_count() > 0:
		return
	_em_cd -= 1
	if _em_cd <= 0:
		_spawn_emerald()
		_em_cd = _next_emerald_interval()


## Roll the spawn position + drift seed from the LCG and ask MatchController to spawn it
## (the hook does SyncManager.spawn). Only counts toward the cap if the hook actually
## spawned (the hook returns false when emerald_scene is null — the headless "freeze").
func _spawn_emerald() -> void:
	var ox: int = (_next_emerald_rng() % 281) - 140   # -140..140 sim units from centre
	var oy: int = (_next_emerald_rng() % 361) - 180   # -180..180 sim units from centre
	var seed_v: int = _next_emerald_rng()
	if _em_spawn_hook.is_valid() and bool(_em_spawn_hook.call(ox, oy, seed_v)):
		_em_cnt += 1


## Whole ticks until the next emerald, from the LCG (min .. min+span).
func _next_emerald_interval() -> int:
	return _em_min_ticks + (_next_emerald_rng() % maxi(1, _em_span_ticks))


## Advances the seeded LCG (masked to 32 bits so the multiply never overflows int64).
func _next_emerald_rng() -> int:
	_em_rng = (_em_rng * 1664525 + 1013904223) & 0xffffffff
	return _em_rng


## (Re)seed the cadence for the current round (mixing the round number so rounds differ
## but replay identically) + arm the first countdown. Called on each round / match reset.
func _reseed_emeralds() -> void:
	_em_rng = (_em_base_seed + _round_number * 2654435761) & 0xffffffff
	_em_cd = _next_emerald_interval()


## Live emerald count via the deterministic "pickups" group membership (a despawned
## emerald is detached, so this excludes the retire window). Null-guarded.
func _live_pickup_count() -> int:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	return tree.get_nodes_in_group(&"pickups").size()


## Despawn any live emerald IN-TICK (KO / round reset) through its own rollback-aware
## _despawn(), so it never lingers across a round boundary nor dangles a spawn record.
func _clear_emeralds() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group(&"pickups"):
		if n.has_method(&"_despawn"):
			n._despawn()
		elif is_instance_valid(n):
			n.queue_free()


## Frees every projectile through its rollback-aware _despawn() (→ SyncManager.despawn
## under a live match, queue_free offline). Called IN-TICK, so the despawn lands on a
## sim tick — the whole point of Sub-phase 3 (a bare off-tick queue_free dangled the
## spawn record and crashed the next rollback).
func _clear_projectiles() -> void:
	if _projectiles == null or not is_instance_valid(_projectiles):
		return
	for child in _projectiles.get_children():
		if child.has_method(&"_despawn"):
			child._despawn()
		else:
			child.queue_free()


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in netplay.
func _physics_process(_delta: float) -> void:
	if local_tick_driver_enabled:
		_network_process({})


func _save_state() -> Dictionary:
	return {
		"ph": _phase,
		"cd": _countdown,
		"ps": _player_score,
		"os": _opponent_score,
		"rn": _round_number,
		"wn": _winner,
		"erng": _em_rng,
		"ecd": _em_cd,
		"ecnt": _em_cnt,
	}


func _load_state(state: Dictionary) -> void:
	_phase = int(state.get("ph", Phase.ACTIVE))
	_countdown = int(state.get("cd", 0))
	_player_score = int(state.get("ps", 0))
	_opponent_score = int(state.get("os", 0))
	_round_number = int(state.get("rn", 1))
	_winner = int(state.get("wn", 0))
	_em_rng = int(state.get("erng", 0))
	_em_cd = int(state.get("ecd", 0))
	_em_cnt = int(state.get("ecnt", 0))
