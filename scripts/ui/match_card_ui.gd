## match_card_ui.gd — the IN-ROUND card variant (Card Creation Engine).
##
## A standalone, reusable card face for cards held during ACTIVE GAMEPLAY. It assembles the raw
## CardResource.card_art (cover-filled + cropped) UNDER the universal border_in_round.png frame, with the
## card NAME overlaid procedurally. STRICT TCG 5:7 aspect (like Magic / Pokémon) — keep the instance's
## container 5:7 so nothing distorts.
##
## ROBUST FALLBACKS (Phase 2): no card_art → the procedural TYPE GLYPH; no border PNG → the procedural
## gold placeholder frame. A procedural RARITY shape sits bottom-centre.
##
## STRICT RULE: NO rules text / description is EVER rendered here (art + name only). PRESENTATION ONLY.
## USE: instance scenes/match_card_ui.tscn, then call setup(card) — or assign the `card` export.
class_name MatchCardUI
extends Control

## The universal in-round frame (drop your border_in_round.png here). Guarded: missing → the procedural
## placeholder frame is used instead.
const BORDER_PATH := "res://resources/cards/frames/border_in_round.png"

## Reference 5:7 size. The scene is authored at this; scale the instance as one unit to resize.
const REF_SIZE := Vector2(500.0, 700.0)

## Card-Type tints (Phase 2: the universal border is grayscale, tinted by type via modulate).
const TYPE_COL := {0: Color(0.92, 0.36, 0.32), 1: Color(0.34, 0.78, 0.46), 2: Color(0.36, 0.6, 0.98)}

## Drop a CardResource here to preview in-editor / drive at runtime.
@export var card: CardResource:
	set(value):
		card = value
		if is_inside_tree():
			_apply()

@onready var _art: TextureRect = $ArtWell/Art
@onready var _art_fallback: TypeGlyphIcon = $ArtWell/ArtFallback
@onready var _border: TextureRect = $Border
@onready var _border_fallback: PlaceholderBorder = $BorderFallback
@onready var _rarity: RarityIcon = $Rarity
@onready var _name: Label = $NameLabel


func _ready() -> void:
	# Real frame PNG if present; else the procedural gold placeholder (Phase 2 robust fallback).
	var has_png := ResourceLoader.exists(BORDER_PATH)
	if has_png:
		_border.texture = load(BORDER_PATH)
	_border.visible = has_png
	_border_fallback.visible = not has_png
	_apply()


## Point this card at a CardResource (fills art + name + rarity). Safe before OR after the node is in-tree.
func setup(c: CardResource) -> void:
	card = c   # triggers the setter (which _apply()s once in-tree)


func _apply() -> void:
	if _art == null:
		return   # not ready yet — _ready() will re-apply
	if card == null:
		_art.visible = false
		_art_fallback.visible = false
		_name.text = ""
		return
	# Art: the raw card_art, or the procedural type-glyph fallback until base_art is dropped in.
	var has_art := card.card_art != null
	_art.texture = card.card_art
	_art.visible = has_art
	_art_fallback.visible = not has_art
	_art_fallback.card_type = int(card.card_type)
	# Border (PNG + procedural fallback) TINTED by Card Type via modulate.
	var tint: Color = TYPE_COL.get(int(card.card_type), Color(1, 1, 1))
	_border.modulate = tint
	_border_fallback.modulate = tint
	_rarity.rarity = int(card.rarity)
	_name.text = (card.display_name if card.display_name != "" else "").to_upper()
