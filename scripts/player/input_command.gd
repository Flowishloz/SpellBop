## input_command.gd — Command Pattern encoder for one tick of player input.
##
## ROLE: Turns raw Input singleton polling into a compact, serialization-friendly
## Dictionary that can be stored in the input buffer, sent over the network, and
## replayed deterministically during rollback. All gameplay math in this project
## is fixed-point (SG Physics 2D); input commands therefore contain ONLY plain
## ints (never floats, Vector2s, or objects) so they hash/serialize identically
## on every peer.
##
## The canonical input dictionary shape is:
##     { "x": -1 | 0 | 1, "c": 1, "k": 1 | 2 | 3 }
## (each key is OMITTED when at its default — see below).
## An all-default input is represented as an EMPTY dictionary {} — this keeps
## serialized inputs as small as possible (the rollback framework only ships
## non-empty keys) and makes "no input" trivially comparable.
##
## (Sprint 19, Phase 1: the dash bit "d" was removed with the dash ability.)
class_name InputCommand
extends RefCounted

## Dictionary key for horizontal movement axis (-1 = left, 0 = idle, +1 = right).
const KEY_X: StringName = &"x"

## Dictionary key for the cast bit (1 = cast_spell held this tick, key omitted
## otherwise). Consumers that need press-EDGE semantics (e.g. "one cast per
## press") derive them deterministically in-sim from consecutive tick values —
## the raw held state is what predicts/replays correctly under rollback.
const KEY_CAST: StringName = &"c"

## Dictionary key for the card slot held this tick (1 | 2 | 3 — test keys
## 8 / 9 / 0; key omitted when no card is held). One wizard channels one card
## at a time, so a single slot value is the canonical encoding: when several
## card keys are physically held, the LOWEST slot wins deterministically.
## Held state, not edge — same rollback rationale as KEY_CAST.
const KEY_CARD: StringName = &"k"

## Default action names polled by capture_local(). Override by passing a custom
## actions dictionary if a player slot uses prefixed actions (e.g. "p2_move_left").
const DEFAULT_ACTIONS: Dictionary = {
	"left": "move_left",
	"right": "move_right",
	"cast": "cast_spell",
	"card_1": "card_slot_1",
	"card_2": "card_slot_2",
	"card_3": "card_slot_3",
}


## Polls the Input singleton and returns this tick's input as a compact Dictionary.
## [param actions] maps the logical slots "left"/"right" to InputMap action names;
## defaults to {"left": "move_left", "right": "move_right"}.
## Returns {} when no relevant input is held (canonical empty input).
static func capture_local(actions: Dictionary = DEFAULT_ACTIONS) -> Dictionary:
	var left_action: String = actions.get("left", "move_left")
	var right_action: String = actions.get("right", "move_right")
	var cast_action: String = actions.get("cast", "cast_spell")

	# Plain int math only — no Input.get_axis() (returns float).
	var x: int = 0
	if Input.is_action_pressed(right_action):
		x += 1
	if Input.is_action_pressed(left_action):
		x -= 1

	var input: Dictionary = {}
	if x != 0:
		input[KEY_X] = x
	if Input.is_action_pressed(cast_action):
		input[KEY_CAST] = 1

	# Card slot held this tick (lowest slot wins — deterministic tiebreak).
	for slot in [1, 2, 3]:
		var card_action: String = actions.get("card_%d" % slot, "card_slot_%d" % slot)
		if InputMap.has_action(card_action) and Input.is_action_pressed(card_action):
			input[KEY_CARD] = slot
			break

	return input


## Returns the horizontal axis value (-1, 0, or +1) from an input Dictionary,
## tolerating the compact empty form.
static func get_x(input: Dictionary) -> int:
	return int(input.get(KEY_X, 0))


## Returns the cast bit (1 = cast_spell held this tick, 0 otherwise) from an
## input Dictionary, tolerating the compact empty form.
static func get_cast(input: Dictionary) -> int:
	return int(input.get(KEY_CAST, 0))


## Returns the card slot held this tick (1 | 2 | 3, or 0 = none) from an
## input Dictionary, tolerating the compact empty form.
static func get_card(input: Dictionary) -> int:
	return int(input.get(KEY_CARD, 0))


## True if this input represents "no buttons held" (the canonical empty input).
static func is_empty(input: Dictionary) -> bool:
	return input.is_empty() or (get_x(input) == 0 and get_cast(input) == 0
			and get_card(input) == 0)


## Value-equality between two input dictionaries, treating missing keys as
## defaults (so {} equals {"x": 0, "c": 0, "k": 0}). Use this instead of ==
## when comparing predicted vs. confirmed inputs.
static func equals(a: Dictionary, b: Dictionary) -> bool:
	return get_x(a) == get_x(b) and get_cast(a) == get_cast(b) \
			and get_card(a) == get_card(b)


## Returns a new canonical empty input. Provided for readability at call sites.
static func empty() -> Dictionary:
	return {}
