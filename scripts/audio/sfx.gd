## sfx.gd — Compile-safe static gateway to the SoundFX autoload.
##
## WHY: referencing the autoload identifier `SoundFX` directly fails to
## compile in standalone script contexts (headless --check-only, early
## import ordering) — the same "Failed to load script" console-noise class
## the Creative Director flagged. This class_name resolves from the global
## class cache instead, and looks the autoload up defensively at call time
## (the established house pattern for TheStack/GameSettings).
class_name Sfx
extends Object


## Fire-and-forget. Silently no-ops if the SoundFX autoload is absent
## (stripped headless harnesses).
static func play(sfx_name: StringName, volume_db: float = 0.0) -> void:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		var node: Node = (loop as SceneTree).root.get_node_or_null("SoundFX")
		if node != null:
			node.play(sfx_name, volume_db)
