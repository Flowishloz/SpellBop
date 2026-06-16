## wizard_pose_manifest.gd — the generated index of wizard POSE textures.
##
## Written by the WizardPipeline editor plugin (addons/wizard_pipeline/) whenever a PNG is
## added / renamed / removed in res://assets_final/sprites/wizards/, and read at runtime by
## WizardPoseLibrary. It is a real Resource (.tres) so it loads reliably in EXPORTED mobile
## builds, where res:// directory listing is unreliable on-device.
@tool
class_name WizardPoseManifest
extends Resource

## Pose name = the PNG filename without extension, e.g. &"idle", &"cast_fire".
@export var names: PackedStringArray = PackedStringArray()

## res:// path to each pose PNG, index-aligned with `names`.
@export var paths: PackedStringArray = PackedStringArray()
