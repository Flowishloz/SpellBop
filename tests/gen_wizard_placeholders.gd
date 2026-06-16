## gen_wizard_placeholders.gd — bootstraps the character pipeline's PLACEHOLDER assets so it
## is testable before the Creative Director's real Aseprite art lands:
##   * 8 distinct 128x128 pose PNGs in res://assets_final/sprites/wizards/
##   * default_blue.tres (identity) + default_red.tres (robe recolour) skins
##   * wizard_pose_manifest.tres
## The reference-palette colours defined here ARE the swap palette (default_blue.colors), so
## the artist can later paint over the PNGs using these exact hex codes and skins keep working.
## Run once:  <godot> --path . -s res://tests/gen_wizard_placeholders.gd
## Overwrite any PNG with real art any time — the pipeline keys poses by filename.
extends SceneTree

const W := 128
const OUT_DIR := "res://assets_final/sprites/wizards/"
const SKIN_DIR := "res://assets_final/skins/"
const MANIFEST := "res://assets_final/sprites/wizard_pose_manifest.tres"

# Reference palette — index order is STABLE (skins remap BY INDEX). sRGB.
#   0 outline  1 robe  2 robe_dark  3 robe_light  4 skin  5 skin_dark  6 hat_star  7 eye
var REF := [
	Color8(26, 20, 38), Color8(59, 93, 201), Color8(42, 61, 143), Color8(107, 140, 255),
	Color8(240, 201, 160), Color8(201, 143, 107), Color8(255, 211, 77), Color8(245, 245, 245),
]
# default_red: remap the three robe slots (1/2/3) to crimson; everything else identity.
var RED := [
	Color8(26, 20, 38), Color8(201, 59, 59), Color8(143, 42, 42), Color8(255, 120, 120),
	Color8(240, 201, 160), Color8(201, 143, 107), Color8(255, 211, 77), Color8(245, 245, 245),
]

var POSES := [
	{"name": "idle",        "arm": "down", "accent": Color8(150, 150, 160)},
	{"name": "running",     "arm": "down", "accent": Color8(120, 230, 140), "dx": 4, "stride": true},
	{"name": "charging",    "arm": "up",   "accent": Color8(255, 211, 77)},
	{"name": "cast_fire",   "arm": "fwd",  "accent": Color8(255, 140, 40)},
	{"name": "cast_ice",    "arm": "fwd",  "accent": Color8(120, 210, 255)},
	{"name": "cast_shield", "arm": "up",   "accent": Color8(230, 240, 255), "shield": true},
	{"name": "hurt",        "arm": "down", "accent": Color8(230, 70, 70),  "xeyes": true, "shear": -6},
	{"name": "close_call",  "arm": "down", "accent": Color8(255, 230, 90), "shear": 7, "sweat": true},
]


func _init() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SKIN_DIR))

	for pose in POSES:
		var img: Image = _draw(pose)
		var path: String = OUT_DIR + str(pose["name"]) + ".png"
		img.save_png(path)
		print("wrote ", path)

	_save_skin("default_blue", "Azure Apprentice", REF, SKIN_DIR + "default_blue.tres")
	_save_skin("default_red", "Crimson Apprentice", RED, SKIN_DIR + "default_red.tres")
	_save_manifest()
	print("DONE: placeholders + skins + manifest")
	quit(0)


func _save_skin(id: String, disp: String, cols: Array, path: String) -> void:
	var skin := SkinPalette.new()
	skin.id = StringName(id)
	skin.display_name = disp
	var pc := PackedColorArray()
	for c in cols:
		pc.append(c)
	skin.colors = pc
	ResourceSaver.save(skin, path)
	print("wrote ", path)


func _save_manifest() -> void:
	var m := WizardPoseManifest.new()
	var names := PackedStringArray()
	var paths := PackedStringArray()
	for pose in POSES:
		names.append(str(pose["name"]))
		paths.append(OUT_DIR + str(pose["name"]) + ".png")
	m.names = names
	m.paths = paths
	ResourceSaver.save(m, MANIFEST)
	print("wrote ", MANIFEST)


# =====================================================================
# Drawing
# =====================================================================

func _draw(pose: Dictionary) -> Image:
	var img := Image.create(W, W, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx: int = 64 + int(pose.get("dx", 0))
	var O: Color = REF[0]
	var ROBE: Color = REF[1]
	var ROBE_D: Color = REF[2]
	var SKIN: Color = REF[4]
	var STAR: Color = REF[6]
	var EYE: Color = REF[7]

	# robe body (trapezoid, shoulders -> hem) with a shaded left edge + outline
	for y in range(66, 117):
		var t: float = float(y - 66) / 50.0
		var half: int = int(round(lerpf(15.0, 28.0, t)))
		_rect(img, cx - half, y, cx + half, y, ROBE)
		_rect(img, cx - half, y, cx - half + 4, y, ROBE_D)
		_px(img, cx - half, y, O)
		_px(img, cx + half, y, O)
	_rect(img, cx - 28, 116, cx + 28, 117, O)

	# feet
	if bool(pose.get("stride", false)):
		_rect(img, cx - 16, 118, cx - 8, 123, ROBE_D)
		_rect(img, cx + 8, 116, cx + 16, 121, ROBE_D)
	else:
		_rect(img, cx - 12, 118, cx - 4, 123, ROBE_D)
		_rect(img, cx + 4, 118, cx + 12, 123, ROBE_D)

	# arms
	match str(pose.get("arm", "down")):
		"up":
			_limb(img, cx - 14, 74, cx - 22, 44, ROBE)
			_disc(img, cx - 22, 42, 4, SKIN)
			_limb(img, cx + 14, 74, cx + 22, 44, ROBE)
			_disc(img, cx + 22, 42, 4, SKIN)
		"fwd":
			_limb(img, cx + 12, 78, cx + 34, 70, ROBE)
			_disc(img, cx + 35, 70, 4, SKIN)
			_limb(img, cx - 12, 76, cx - 16, 100, ROBE)
			_disc(img, cx - 16, 102, 4, SKIN)
		_:
			_limb(img, cx - 14, 74, cx - 18, 102, ROBE)
			_disc(img, cx - 18, 104, 4, SKIN)
			_limb(img, cx + 14, 74, cx + 18, 102, ROBE)
			_disc(img, cx + 18, 104, 4, SKIN)

	# head
	_disc(img, cx, 52, 15, SKIN)
	# eyes
	if bool(pose.get("xeyes", false)):
		_xeye(img, cx - 6, 50, O)
		_xeye(img, cx + 6, 50, O)
	else:
		_disc(img, cx - 6, 51, 3, EYE)
		_disc(img, cx + 6, 51, 3, EYE)
		_disc(img, cx - 6, 51, 1, O)
		_disc(img, cx + 6, 51, 1, O)

	# hat (cone + brim + tip star) — drawn over the head top
	for y in range(12, 41):
		var t2: float = float(y - 12) / 28.0
		var half2: int = int(round(lerpf(2.0, 22.0, t2)))
		_rect(img, cx - half2, y, cx + half2, y, ROBE)
		_px(img, cx - half2, y, O)
		_px(img, cx + half2, y, O)
	_rect(img, cx - 26, 40, cx + 26, 42, ROBE_D)
	_rect(img, cx - 26, 43, cx + 26, 43, O)
	_disc(img, cx, 14, 3, STAR)

	# chest accent gem (an out-of-palette colour -> passes through the skin swap unchanged)
	var accent: Color = pose.get("accent", Color8(150, 150, 160))
	_disc(img, cx, 86, 7, O)
	_disc(img, cx, 86, 5, accent)

	# shield arc (cast_shield)
	if bool(pose.get("shield", false)):
		for y in range(58, 104):
			_px(img, cx + 30, y, Color(accent.r, accent.g, accent.b, 0.9))
			_px(img, cx + 31, y, Color(accent.r, accent.g, accent.b, 0.6))
			_px(img, cx + 29, y, Color(accent.r, accent.g, accent.b, 0.6))

	# sweat drop (close_call)
	if bool(pose.get("sweat", false)):
		_disc(img, cx + 16, 44, 2, Color8(150, 210, 255))

	# lean shear (hurt / close_call) — baked into the texture (the billboard ignores node roll)
	var shear: int = int(pose.get("shear", 0))
	if shear != 0:
		img = _shear(img, shear)
	return img


func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < W and y < W:
		img.set_pixel(x, y, c)


func _rect(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	for y in range(mini(y0, y1), maxi(y0, y1) + 1):
		for x in range(mini(x0, x1), maxi(x0, x1) + 1):
			_px(img, x, y, c)


func _disc(img: Image, cx: int, cy: int, r: int, c: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			var dx: int = x - cx
			var dy: int = y - cy
			if dx * dx + dy * dy <= r * r:
				_px(img, x, y, c)


func _limb(img: Image, x0: int, y0: int, x1: int, y1: int, fill: Color) -> void:
	var steps: int = maxi(absi(x1 - x0), absi(y1 - y0)) + 1
	for i in steps + 1:
		var tt: float = float(i) / float(steps)
		var x: int = int(round(lerpf(float(x0), float(x1), tt)))
		var y: int = int(round(lerpf(float(y0), float(y1), tt)))
		_disc(img, x, y, 3, fill)


func _xeye(img: Image, cx: int, cy: int, c: Color) -> void:
	for i in range(-2, 3):
		_px(img, cx + i, cy + i, c)
		_px(img, cx + i, cy - i, c)


func _shear(src: Image, amount: int) -> Image:
	var dst := Image.create(W, W, false, Image.FORMAT_RGBA8)
	dst.fill(Color(0, 0, 0, 0))
	for y in W:
		var sx: int = int(round((64.0 - float(y)) / 64.0 * float(amount)))
		for x in W:
			var c: Color = src.get_pixel(x, y)
			if c.a > 0.0:
				var nx: int = x + sx
				if nx >= 0 and nx < W:
					dst.set_pixel(nx, y, c)
	return dst
