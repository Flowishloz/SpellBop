## screenshot_hover.gd — forces GameSettings.hover_mode ON (in memory, so the user's cfg is untouched)
## then screenshots a scene, to verify the OPTIONAL hover/flight animation. NOT headless — needs a GPU.
## arg: "cosmetics" | "match" | "home" (default "match"). Run: <godot> --path . -s res://tests/screenshot_hover.gd ++ match
extends SceneTree

const OUT := "res://tests/_screenshot.png"
const SCENES := {
	"cosmetics": "res://scenes/cosmetics.tscn",
	"match": "res://scenes/match_arena.tscn",
	"home": "res://scenes/home_screen.tscn",
}


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var which := "match"
	for arg in OS.get_cmdline_user_args():
		which = arg
	var gs: Node = root.get_node_or_null("GameSettings")
	if gs != null:
		gs.set(&"hover_mode", true)   # IN MEMORY only — animators read it in _ready / via the signal
	root.add_child(load(SCENES.get(which, SCENES["match"])).instantiate())
	for i in 130:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: hover scene='", which, "' -> ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
