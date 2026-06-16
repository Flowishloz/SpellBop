## wizard_pose_manifest.gd — the generated, FACING-AWARE index of base wizard pose textures.
##
## Written by the WizardPipeline editor plugin whenever a PNG is added / renamed / removed in
## res://assets_final/sprites/wizards/, and read at runtime by WizardPoseLibrary. A real
## Resource (.tres) so it loads reliably in EXPORTED mobile builds (res:// dir listing is
## unreliable on-device).
##
## DIRECTIONAL: each pose has a FRONT (facing camera) and a BACK (facing away) texture. The
## plugin groups <pose>_front.png / <pose>_back.png by pose; a no-suffix <pose>.png fills BOTH
## facings (back-compat). The three arrays are parallel — index i is one pose. A "" path means
## that facing is absent (the library falls back front<->back, then to idle).
@tool
class_name WizardPoseManifest
extends Resource

## Pose name (PNG basename without the _front/_back suffix), e.g. &"idle", &"cast_fire".
@export var pose_names: PackedStringArray = PackedStringArray()
## res:// path to each pose's FRONT texture, index-aligned with pose_names ("" if absent).
@export var front_paths: PackedStringArray = PackedStringArray()
## res:// path to each pose's BACK texture, index-aligned with pose_names ("" if absent).
@export var back_paths: PackedStringArray = PackedStringArray()
