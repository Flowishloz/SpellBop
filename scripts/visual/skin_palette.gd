## skin_palette.gd — a wizard SKIN as a colour-swap palette (the monetisation data half).
##
## PRESENTATION ONLY — never touches the deterministic sim.
##
## COLOUR-MATCH model (palette_swap.gdshader): the BASE skin's `colors` ARE the reference
## palette the artist paints with (the shader's src). Any skin's `colors` are the recolour
## (dst) — SAME length + SAME order as the base. New skins = new .tres dropped in
## res://assets_final/skins/ (shop / wardrobe ready). The identity skin (default_blue) sets
## `colors` == the exact palette the art was drawn in.
@tool
class_name SkinPalette
extends Resource

## Stable id — shop key / save-data key. e.g. &"default_blue".
@export var id: StringName = &""

## Player-facing name (wardrobe UI).
@export var display_name: String = ""

## The recolour: ONE sRGB Color per reference-palette slot, in the SAME order as the base
## skin's palette. The colours you pick in Aseprite. Keep <= 16 entries (shader cap).
@export var colors: PackedColorArray = PackedColorArray()

## PREMIUM (geometry) skin: an optional res:// folder of REPLACEMENT pose art. Empty = use the
## shared base set (assets_final/sprites/wizards/ via the manifest). Non-empty (e.g.
## "res://assets_final/skins/cyber_wizard/") = pull each pose's <pose>_front.png / <pose>_back.png
## from THAT folder instead (a completely different silhouette / hat), STILL palette-swapped by
## the same shader. Poses the folder lacks fall back to that folder's idle. This is how a premium
## skin changes the wizard's SHAPE, not just its colours.
@export_dir var texture_folder_override: String = ""

## Shop hook (future in-game store). 0 = owned / default / free.
@export var price: int = 0
