## wizard_pose_library.gd — runtime pose registry for the character pipeline.
##
## Loads the generated pose manifest (or, in-editor, falls back to a live folder scan) and
## hands out pose Textures BY NAME. PRESENTATION ONLY — pure texture lookup, zero sim /
## rollback state, so it can never desync.
##
## DYNAMIC by design: poses are keyed by PNG filename, so dropping a new <pose>.png into
## res://assets_final/sprites/wizards/ registers it with NO code change. A missing pose
## returns null and the animator keeps whatever texture it is already showing.
@tool
class_name WizardPoseLibrary
extends Object

const DIR := "res://assets_final/sprites/wizards/"
const MANIFEST := "res://assets_final/sprites/wizard_pose_manifest.tres"

static var _poses: Dictionary = {}   # StringName -> Texture2D
static var _loaded: bool = false


## The pose Texture for `pose`, or null if no such PNG was registered.
static func get_pose(pose: StringName) -> Texture2D:
	if not _loaded:
		_load()
	return _poses.get(pose, null)


static func has_pose(pose: StringName) -> bool:
	if not _loaded:
		_load()
	return _poses.has(pose)


static func pose_names() -> Array:
	if not _loaded:
		_load()
	return _poses.keys()


## Force a re-read (the editor plugin calls this after regenerating the manifest).
static func reload() -> void:
	_loaded = false
	_poses.clear()
	_load()


static func _load() -> void:
	_loaded = true
	_poses.clear()
	# Prefer the manifest (the only thing that works in exports). Fall back to a live
	# directory scan, which only succeeds in the editor / on desktop.
	if ResourceLoader.exists(MANIFEST):
		var manifest: WizardPoseManifest = load(MANIFEST) as WizardPoseManifest
		if manifest != null and manifest.names.size() == manifest.paths.size() and manifest.names.size() > 0:
			for i in manifest.names.size():
				var tex: Texture2D = load(manifest.paths[i]) as Texture2D
				if tex != null:
					_poses[StringName(manifest.names[i])] = tex
			return
	_scan_dir()


static func _scan_dir() -> void:
	var d: DirAccess = DirAccess.open(DIR)
	if d == null:
		return
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		if not d.current_is_dir() and f.get_extension() == "png":
			var tex: Texture2D = load(DIR + f) as Texture2D
			if tex != null:
				_poses[StringName(f.get_basename())] = tex
		f = d.get_next()
	d.list_dir_end()
