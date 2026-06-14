## sound_fx.gd — One-shot SFX dispatcher (autoload: SoundFX).
##
## ROLE: the single place gameplay/UI code asks for a sound. Each play()
## spins up a throwaway AudioStreamPlayer that frees itself — no pools, no
## channels, placeholder-grade by design.
##
## All streams live in res://audio/sfx/<name>.wav (PLACEHOLDERS, synthesized,
## normalized to roughly -18/-20 LUFS — see Wizard_Dodgeball_Brain/
## AUDIO_GUIDE.md for the full trigger map and replacement instructions).
## Replacing a sound = dropping a new .wav over the same filename.
##
## PROCESS_MODE_ALWAYS so UI clicks still sound while the tree is paused
## (the ESC settings menu).
extends Node

const SFX_DIR := "res://audio/sfx/"

const NAMES: Array[StringName] = [
	&"cast_fireball", &"release_bolt", &"stage_slap",
	&"shield_deploy", &"shield_capture", &"shield_release",
	&"counter_wave", &"hit_wizard", &"frost_hit",
	&"wall_bounce", &"heal",
	&"round_win", &"round_lose", &"victory", &"ui_click",
	&"tape_slow", &"stopwatch_tick", &"slap_on_card", &"shield_shatter",
]

var _streams: Dictionary = {}

# Last live player per sound: a retrigger CROSSFADES the old instance out
# instead of letting identical sounds pile up phase-on-phase (Creative
# Director: "fade the previous sound out as a new one overlaps it").
# DIFFERENT sounds still layer freely.
var _last_player: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for sfx_name in NAMES:
		var path: String = SFX_DIR + String(sfx_name) + ".wav"
		if ResourceLoader.exists(path):
			_streams[sfx_name] = load(path)
		else:
			push_warning("SoundFX: missing stream %s" % path)


## Fire-and-forget. Unknown names warn once via the missing-stream check.
func play(sfx_name: StringName, volume_db: float = 0.0) -> void:
	var stream: AudioStream = _streams.get(sfx_name)
	if stream == null:
		return

	# Crossfade a still-playing instance of the SAME sound out of the way.
	# GRAVEYARD-CLASS GOTCHA (crash log 2026-06-12): a finished player frees
	# itself while the dictionary still holds the dead reference — pulling
	# that into a TYPED variable is a hard script error ("Trying to assign
	# invalid previously freed instance"). Retrieve UNTYPED, gate on
	# is_instance_valid, only then cast.
	var prev_ref: Variant = _last_player.get(sfx_name)
	if is_instance_valid(prev_ref):
		var prev: AudioStreamPlayer = prev_ref as AudioStreamPlayer
		if prev != null and prev.playing:
			var fade: Tween = prev.create_tween()
			fade.tween_property(prev, "volume_db", -30.0, 0.12)
			fade.tween_callback(prev.queue_free)

	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = &"Master"
	add_child(player)
	# On natural finish: free AND clear the cache slot (only if this player
	# still owns it — a crossfade may have replaced it already).
	player.finished.connect(func() -> void:
		if _last_player.get(sfx_name) == player:
			_last_player.erase(sfx_name)
		player.queue_free())
	player.play()
	_last_player[sfx_name] = player
