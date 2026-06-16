## wizard_pose_library.gd — runtime pose registry for the character pipeline.
##
## Loads pose textures BY (pose, facing) and optionally from a PREMIUM skin's override folder.
## PRESENTATION ONLY — pure texture lookup, zero sim / rollback state, so it can never desync.
##
## DIRECTIONAL: every pose has a FRONT (facing camera) + BACK (facing away) texture. DYNAMIC:
## poses are keyed by filename, so dropping <pose>_front.png / <pose>_back.png registers them
## with no code change. PREMIUM: a non-empty `folder` pulls the art from that folder instead
## (different silhouette), still palette-swapped by the shader.
##
## Loading strategy:
##   - BASE (folder == ""): via the generated manifest (export-robust), falling back to a live
##     directory scan in the editor.
##   - PREMIUM (folder set): by CONSTRUCTED PATH — load(folder/<pose>_<facing>.png) — which works
##     in exported builds (no res:// directory listing needed). Negative results are cached too.
## Fallback chain for a missing texture: requested facing -> other facing -> idle (same facing)
## -> idle (other facing) -> null (the animator then keeps whatever it is already showing).
@tool
class_name WizardPoseLibrary
extends Object

const BASE_DIR := "res://assets_final/sprites/wizards/"
const MANIFEST := "res://assets_final/sprites/wizard_pose_manifest.tres"

static var _base: Dictionary = {}          # pose(StringName) -> {front: Texture2D|null, back: Texture2D|null}
static var _base_loaded: bool = false
static var _folder_cache: Dictionary = {}  # "folder|pose|facing" -> Texture2D|null (null = tried, absent)


## The pose Texture for (pose, facing), from `folder` (premium) or the base set. Applies the
## front<->back<->idle fallback chain; returns null only if nothing usable exists.
static func get_pose(pose: StringName, facing: StringName, folder: String = "") -> Texture2D:
	var other: StringName = &"back" if facing == &"front" else &"front"
	var t: Texture2D = _fetch(pose, facing, folder)
	if t == null:
		t = _fetch(pose, other, folder)
	if t == null and pose != &"idle":
		t = _fetch(&"idle", facing, folder)
		if t == null:
			t = _fetch(&"idle", other, folder)
	return t


## True if the base set has this pose at all (either facing). Used for optional poses (e.g. a
## dedicated cast_spark) — folder skins are checked lazily via get_pose instead.
static func has_pose(pose: StringName) -> bool:
	_ensure_base()
	return _base.has(pose)


## Force a re-read (the editor plugin calls this after regenerating the manifest).
static func reload() -> void:
	_base_loaded = false
	_base.clear()
	_folder_cache.clear()
	_ensure_base()


# --- internals -------------------------------------------------------------

static func _fetch(pose: StringName, facing: StringName, folder: String) -> Texture2D:
	if folder.is_empty():
		_ensure_base()
		var entry: Variant = _base.get(pose)
		if entry == null:
			return null
		return entry.get(facing)
	# Premium folder: load by constructed path (export-safe), caching negatives too.
	var key: String = folder + "|" + str(pose) + "|" + str(facing)
	if _folder_cache.has(key):
		return _folder_cache[key]
	var dir: String = folder if folder.ends_with("/") else folder + "/"
	var tex: Texture2D = _load_tex(dir + str(pose) + "_" + str(facing) + ".png")
	if tex == null:
		tex = _load_tex(dir + str(pose) + ".png")  # no-suffix art serves both facings
	_folder_cache[key] = tex
	return tex


static func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


static func _ensure_base() -> void:
	if _base_loaded:
		return
	_base_loaded = true
	_base.clear()
	if ResourceLoader.exists(MANIFEST):
		var m: WizardPoseManifest = load(MANIFEST) as WizardPoseManifest
		if m != null and m.pose_names.size() == m.front_paths.size() and m.pose_names.size() == m.back_paths.size() and m.pose_names.size() > 0:
			for i in m.pose_names.size():
				_base[StringName(m.pose_names[i])] = {
					&"front": _load_tex(m.front_paths[i]),
					&"back": _load_tex(m.back_paths[i]),
				}
			return
	_scan_base()


## Editor / desktop fallback when no manifest exists: group the folder's PNGs by pose + facing.
static func _scan_base() -> void:
	var d: DirAccess = DirAccess.open(BASE_DIR)
	if d == null:
		return
	var fronts: Dictionary = {}
	var backs: Dictionary = {}
	var plain: Dictionary = {}
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		if not d.current_is_dir() and f.get_extension() == "png":
			var base: String = f.get_basename()
			var path: String = BASE_DIR + f
			if base.ends_with("_front"):
				fronts[base.trim_suffix("_front")] = path
			elif base.ends_with("_back"):
				backs[base.trim_suffix("_back")] = path
			else:
				plain[base] = path
		f = d.get_next()
	d.list_dir_end()
	var poses: Dictionary = {}
	for k in fronts: poses[k] = true
	for k in backs: poses[k] = true
	for k in plain: poses[k] = true
	for pose in poses:
		var fp: String = fronts.get(pose, plain.get(pose, ""))
		var bp: String = backs.get(pose, plain.get(pose, ""))
		_base[StringName(pose)] = {&"front": _load_tex(fp), &"back": _load_tex(bp)}
