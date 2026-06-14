## game_settings.gd — Player preferences (autoload: GameSettings).
##
## ROLE: the single source of truth for presentation/control preferences.
## PURE PRESENTATION: nothing here touches the deterministic sim — handedness
## mirrors the camera and HUD layout only; the SG2D plane is untouched.
##
## Consumers read the value in _ready() AND connect to the changed signal so
## toggling mid-match re-flows everything live.
extends Node

## Fired whenever left_handed flips.
signal handedness_changed(left_handed: bool)

## LEFT-HANDED MODE (Creative Director): camera over the LEFT shoulder and
## every HUD element mirrored (hand/dash on the left thumb side, health bar
## top-right) — the §6 dual-thumb layout for left-dominant players.
var left_handed: bool = false


func set_left_handed(value: bool) -> void:
	if left_handed == value:
		return
	left_handed = value
	handedness_changed.emit(left_handed)


## Mirrors an X coordinate across the 1080-wide portrait canvas when in
## left-handed mode (identity otherwise). HUD layout helper.
func mirror_x(x: float) -> float:
	return 1080.0 - x if left_handed else x
