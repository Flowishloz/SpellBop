## probe_billboard_override.gd — DOES a ShaderMaterial in Sprite3D.material_override
## preserve the FIXED_Y billboard? Renders one sprite under a yawed pivot at yaw 0
## vs 70 deg and compares its on-screen GREEN width.
##   width(70)/width(0) ~ 1.0  -> billboard PRESERVED (sprite still faces camera)
##   width(70)/width(0) ~ 0.34 -> billboard LOST (quad turned edge-on, cos 70 = 0.34)
## Decides whether palette_swap.gdshader must re-implement billboard in vertex()
## (and whether the death flat-spin's negative scale.x survives).
## Run (NEEDS A WINDOW/GPU, not --headless):
##   <godot> --path . -s res://tests/probe_billboard_override.gd
extends SceneTree

var _sprite: Sprite3D
var _pivot: Node3D


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 4.0)  # dead in front, looking down -Z
	root.add_child(cam)
	cam.make_current()

	_pivot = Node3D.new()
	root.add_child(_pivot)

	_sprite = Sprite3D.new()
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	_sprite.texture = ImageTexture.create_from_image(img)  # only sizes the quad
	_sprite.pixel_size = 0.02                               # 64 * 0.02 = 1.28 m
	_sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() { ALBEDO = vec3(0.15, 1.0, 0.30); ALPHA = 1.0; }"
	mat.shader = sh
	_sprite.material_override = mat
	_pivot.add_child(_sprite)

	var w0: int = await _measure_width(0.0)
	var w70: int = await _measure_width(deg_to_rad(70.0))
	var ratio: float = float(w70) / float(maxi(1, w0))
	print("BILLBOARD PROBE: width@0=", w0, " width@70=", w70, " ratio=", "%.2f" % ratio)
	if ratio > 0.8:
		print("VERDICT: material_override PRESERVES billboard (ratio ~1) — fragment-only shader OK.")
	elif ratio < 0.55:
		print("VERDICT: material_override LOSES billboard (~cos70) — shader MUST billboard in vertex().")
	else:
		print("VERDICT: INCONCLUSIVE — inspect the saved PNGs.")
	quit(0)


func _measure_width(yaw: float) -> int:
	_pivot.rotation.y = yaw
	for i in 10:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png("res://tests/_billboard_%d.png" % int(round(rad_to_deg(yaw))))
	var w: int = img.get_width()
	var h: int = img.get_height()
	var min_x: int = w
	var max_x: int = -1
	for y in range(0, h, 2):
		for x in w:
			var c: Color = img.get_pixel(x, y)
			if c.g > 0.6 and c.r < 0.5 and c.b < 0.6:
				if x < min_x:
					min_x = x
				if x > max_x:
					max_x = x
	if max_x < min_x:
		return 0
	return max_x - min_x + 1
