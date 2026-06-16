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


## Scan the pose folder and rewrite the manifest — but ONLY when it actually changed, so the
## save (which itself fires filesystem_changed) can't loop.
func _rescan() -> void:
	var names := PackedStringArray()
	var paths := PackedStringArray()
	var d: DirAccess = DirAccess.open(DIR)
	if d != null:
		d.list_dir_begin()
		var found: Array[String] = []
		var f: String = d.get_next()
		while f != "":
			if not d.current_is_dir() and f.get_extension() == "png":
				found.append(f)
			f = d.get_next()
		d.list_dir_end()
		found.sort()  # deterministic order
		for file in found:
			names.append(file.get_basename())
			paths.append(DIR + file)

	var manifest: WizardPoseManifest = null
	if ResourceLoader.exists(MANIFEST):
		manifest = load(MANIFEST) as WizardPoseManifest
	if manifest == null:
		manifest = WizardPoseManifest.new()
	elif manifest.names == names and manifest.paths == paths:
		return  # unchanged — nothing to do (breaks the save -> filesystem_changed loop)

	manifest.names = names
	manifest.paths = paths
	var err: int = ResourceSaver.save(manifest, MANIFEST)
	if err == OK:
		print("[WizardPipeline] pose manifest updated: ", names.size(), " poses ", Array(names))
		WizardPoseLibrary.reload()
	else:
		push_warning("[WizardPipeline] failed to save manifest (err %d)" % err)
