@tool
extends EditorPlugin
## Wizard Pipeline — the Creative Director's DRAG-AND-DROP pose loader.
##
## Watches res://assets_final/sprites/wizards/ and regenerates the pose manifest whenever a
## PNG is added / renamed / removed, so dropping new art "just registers" with no code edits.
## Also adds a "Rescan Wizard Poses" toolbar button for an explicit refresh.
##
## The manifest is a real .tres (WizardPoseManifest) so it survives export to mobile, where
## res:// directory listing is unreliable. WizardPoseLibrary reads it at runtime.

const DIR := "res://assets_final/sprites/wizards/"
const MANIFEST := "res://assets_final/sprites/wizard_pose_manifest.tres"

var _button: Button


func _enter_tree() -> void:
	_button = Button.new()
	_button.text = "Rescan Wizard Poses"
	_button.pressed.connect(_rescan)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _button)
	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if not fs.filesystem_changed.is_connected(_rescan):
		fs.filesystem_changed.connect(_rescan)
	_rescan()


func _exit_tree() -> void:
	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if fs != null and fs.filesystem_changed.is_connected(_rescan):
		fs.filesystem_changed.disconnect(_rescan)
	if _button != null:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _button)
		_button.queue_free()
		_button = null


## Scan the pose folder, group <pose>_front.png / <pose>_back.png (a no-suffix <pose>.png fills
## BOTH facings), and rewrite the FACING-AWARE manifest — but ONLY when it actually changed, so
## the save (which itself fires filesystem_changed) can't loop.
func _rescan() -> void:
	var fronts: Dictionary = {}   # pose -> path
	var backs: Dictionary = {}
	var plain: Dictionary = {}
	var d: DirAccess = DirAccess.open(DIR)
	if d != null:
		d.list_dir_begin()
		var f: String = d.get_next()
		while f != "":
			if not d.current_is_dir() and f.get_extension() == "png":
				var base: String = f.get_basename()
				var path: String = DIR + f
				if base.ends_with("_front"):
					fronts[base.trim_suffix("_front")] = path
				elif base.ends_with("_back"):
					backs[base.trim_suffix("_back")] = path
				else:
					plain[base] = path
			f = d.get_next()
		d.list_dir_end()

	# Union of all pose names, sorted for a deterministic manifest.
	var pose_set: Dictionary = {}
	for k in fronts: pose_set[k] = true
	for k in backs: pose_set[k] = true
	for k in plain: pose_set[k] = true
	var poses: Array = pose_set.keys()
	poses.sort()

	var pose_names := PackedStringArray()
	var front_paths := PackedStringArray()
	var back_paths := PackedStringArray()
	for pose in poses:
		pose_names.append(pose)
		front_paths.append(fronts.get(pose, plain.get(pose, "")))
		back_paths.append(backs.get(pose, plain.get(pose, "")))

	var manifest: WizardPoseManifest = null
	if ResourceLoader.exists(MANIFEST):
		manifest = load(MANIFEST) as WizardPoseManifest
	if manifest == null:
		manifest = WizardPoseManifest.new()
	elif manifest.pose_names == pose_names and manifest.front_paths == front_paths and manifest.back_paths == back_paths:
		return  # unchanged — nothing to do (breaks the save -> filesystem_changed loop)

	manifest.pose_names = pose_names
	manifest.front_paths = front_paths
	manifest.back_paths = back_paths
	var err: int = ResourceSaver.save(manifest, MANIFEST)
	if err == OK:
		print("[WizardPipeline] pose manifest updated: ", pose_names.size(), " poses ", Array(pose_names))
		WizardPoseLibrary.reload()
	else:
		push_warning("[WizardPipeline] failed to save manifest (err %d)" % err)
