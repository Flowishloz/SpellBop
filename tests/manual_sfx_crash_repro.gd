## Crash repro: SoundFX retrigger after the cached player was freed.
extends SceneTree

func _init() -> void:
	_run()

func _run() -> void:
	await process_frame
	var sfx: Node = root.get_node_or_null("SoundFX")
	if sfx == null:
		print("REPRO: SoundFX autoload missing"); quit(1); return
	sfx.play(&"ui_click")
	await process_frame
	# Simulate a natural finish: hard-free the cached player.
	for child in sfx.get_children():
		child.free()
	# Pre-fix this next line crashed with "Trying to assign invalid
	# previously freed instance" inside play().
	sfx.play(&"ui_click")
	await process_frame
	sfx.play(&"ui_click")
	await process_frame
	print("REPRO: freed-player retrigger survived OK")
	quit(0)
