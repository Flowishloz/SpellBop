## screenshot_phase3b.gd — visual smoke for Phase 3 stack UI: stages an attack +
## counter, captures the staged cards GLOWING their type colour near the end of
## the countdown, then captures the STACK WINNER banner after resolution.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_phase3b.gd
extends SceneTree


class ScriptedBrain extends AIBrainComponent:
	var hold_card_slot: int = 0
	var hold_card_ticks: int = 0

	func decide(_tick: int) -> Dictionary:
		var input: Dictionary = {}
		if hold_card_ticks > 0:
			hold_card_ticks -= 1
			input[InputCommand.KEY_CARD] = hold_card_slot
		return input


func _init() -> void:
	_run()


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	arena.emerald_scene = null
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	var brain := ScriptedBrain.new()
	brain.name = "ScriptedBrain"
	brain.cast_interval_ticks = 0
	brain.card_interval_ticks = 0
	brain.counter_enabled = false
	arena.get_node("Player").add_child(brain)
	var stack: Node = root.get_node("TheStack")
	stack.stack_time_scale = 1.0       # normal ticks so input + capture are reliable
	stack.default_window_seconds = 2.6
	root.add_child(arena)
	await _wait(0.6)

	# Stage an ATTACK, then SLAP a COUNTER -> two cards on the stack.
	brain.hold_card_slot = 1
	brain.hold_card_ticks = 6
	await _wait(0.3)
	brain.hold_card_ticks = 0
	await _wait(0.1)
	brain.hold_card_slot = 3
	brain.hold_card_ticks = 6

	# Near the end of the countdown: max glow/shake.
	await _wait(1.9)
	root.get_texture().get_image().save_png("res://tests/_screenshot_p3_stack.png")

	# Resolve -> the WINNER banner flashes.
	await _wait(1.1)
	root.get_texture().get_image().save_png("res://tests/_screenshot_p3_winner.png")

	print("PROBE: saved _screenshot_p3_stack.png + _screenshot_p3_winner.png")
	quit(0)
