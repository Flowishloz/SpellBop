## input_buffer_component.gd — Ring buffer mapping simulation tick -> input Dictionary.
##
## ROLE: Pure data storage for per-tick input commands (see InputCommand).
## Contains NO physics or gameplay logic. The rollback framework (added in a
## later sprint) will re-simulate past ticks; this buffer is where confirmed
## and locally-captured inputs live so they can be replayed deterministically.
##
## Prediction baseline: get_input() returns the LAST KNOWN input for ticks that
## have no stored entry — i.e. "assume the player keeps holding what they were
## holding", which is the standard rollback input-prediction default.
##
## All stored values are plain Dictionaries of ints/strings — never floats or
## objects — so they remain rollback/serialization safe.
class_name InputBufferComponent
extends Node

## Maximum number of ticks retained. Older entries are overwritten as the ring
## wraps. 64 ticks at 60 tps is a little over one second of history, which
## comfortably covers typical rollback windows (8-12 ticks). Increase only if
## the rollback window grows; memory cost is negligible either way.
@export var buffer_capacity: int = 64

# Parallel ring arrays: _ticks[i] holds the tick number stored at slot i
# (or -1 when the slot is unused/invalidated), _inputs[i] the input Dictionary.
var _ticks: PackedInt64Array = PackedInt64Array()
var _inputs: Array[Dictionary] = []

# Most recent tick ever stored, and its input — used as the prediction
# baseline when a requested tick is ahead of everything we know about.
var _latest_tick: int = -1
var _latest_input: Dictionary = {}


func _ready() -> void:
	_resize_storage()


## Stores [param input] for simulation [param tick], overwriting whatever was
## in that ring slot. Inputs must be plain int/string Dictionaries.
func store(tick: int, input: Dictionary) -> void:
	if _ticks.is_empty():
		_resize_storage()
	var slot: int = _slot_for(tick)
	_ticks[slot] = tick
	_inputs[slot] = input
	if tick >= _latest_tick:
		_latest_tick = tick
		_latest_input = input


## Returns the input for [param tick].
## Lookup rules (rollback prediction baseline):
##  1. Exact entry stored for this tick -> return it.
##  2. No exact entry -> return the most recent stored input at or before the
##     requested tick (search bounded by buffer_capacity).
##  3. Nothing known at all -> return the canonical empty input {}.
func get_input(tick: int) -> Dictionary:
	if _ticks.is_empty() or _latest_tick < 0:
		return InputCommand.empty()

	var slot: int = _slot_for(tick)
	if _ticks[slot] == tick:
		return _inputs[slot]

	# Requested tick is at/after everything we know: predict "still holding".
	if tick >= _latest_tick:
		return _latest_input

	# Gap inside the window: walk backwards to the nearest earlier entry.
	for offset in range(1, buffer_capacity):
		var probe_tick: int = tick - offset
		if probe_tick < 0:
			break
		var probe_slot: int = _slot_for(probe_tick)
		if _ticks[probe_slot] == probe_tick:
			return _inputs[probe_slot]

	return InputCommand.empty()


## Invalidates every stored entry older than [param tick]. Call this when the
## rollback framework confirms a frame and history before it is no longer
## needed. (Ring slots are reused anyway; this just prevents stale reads.)
func clear_before(tick: int) -> void:
	for i in range(_ticks.size()):
		if _ticks[i] >= 0 and _ticks[i] < tick:
			_ticks[i] = -1
			_inputs[i] = {}


## Drops ALL stored input history (e.g. on match restart).
func clear() -> void:
	_resize_storage()
	_latest_tick = -1
	_latest_input = {}


func _slot_for(tick: int) -> int:
	return tick % buffer_capacity


func _resize_storage() -> void:
	buffer_capacity = maxi(1, buffer_capacity)
	_ticks.resize(buffer_capacity)
	_ticks.fill(-1)
	_inputs.resize(buffer_capacity)
	for i in range(buffer_capacity):
		_inputs[i] = {}
