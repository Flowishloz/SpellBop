## health_component.gd — Deterministic per-round health pool (Manifesto §2).
##
## ROLE: owns one wizard's health as plain int sim state. 5 points per round
## (Creative Director, round-system sprint); Base Fireball deals 1 damage.
## Health resets completely each round — MatchController's round flow calls
## reset() between rounds (the old auto-reset placeholder is gone).
##
## ROLLBACK CONTRACT: _save_state()/_load_state() with int-only leaves. Damage
## application is driven by deterministic hit detection, so health replays
## bit-identically. No _network_process — health only changes on events.
##
## SIGNALS are the ONLY way UI reads this (signal-driven decoupling; UI never
## modifies sim data). health_changed also re-fires on _load_state so HUDs
## snap to rollback corrections.
class_name HealthComponent
extends Node

## Current/max health changed. UI hook (e.g. the MatchHUD health bar).
signal health_changed(current: int, max_health: int)

## Damage actually landed (amount > 0). Feedback hook — camera shake, hit
## flashes, SFX — fired BEFORE health_changed so listeners can react to the
## impact itself rather than diffing health values.
signal damaged(amount: int)

## Health reached zero. MatchController will own round flow off this signal.
signal knocked_out

## Hit points per round (5 per Creative Director; Base Fireball = 1 damage).
@export var max_health: int = 5

var _health: int = 5


func _ready() -> void:
	_health = max_health


## Current health (int). UI may call this once at startup to initialize, then
## must rely on health_changed.
func get_health() -> int:
	return _health


## Applies [param amount] damage (int). knocked_out fires ONCE, on the
## transition into 0 — MatchController's round flow owns what happens next.
## Deterministic given deterministic callers.
func apply_damage(amount: int) -> void:
	if amount <= 0:
		return
	var was_alive: bool = _health > 0
	_health = maxi(0, _health - amount)
	damaged.emit(amount)
	health_changed.emit(_health, max_health)
	if _health == 0 and was_alive:
		knocked_out.emit()


## Refills to max (round start). Called by MatchController between rounds.
func reset() -> void:
	_health = max_health
	health_changed.emit(_health, max_health)


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

func _save_state() -> Dictionary:
	return {
		"hp": _health,
	}


func _load_state(state: Dictionary) -> void:
	_health = int(state.get("hp", max_health))
	health_changed.emit(_health, max_health)
