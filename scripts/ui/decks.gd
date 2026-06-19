## decks.gd — the BASIC deck builder (Content Engine P4, basic pass).
##
## Lets the player pick the ACTIVE card for each slot (ATTACK / DEFENSE / COUNTER) from the card pool
## (CardCatalog), persisted via PlayerProfile. OFFLINE matches then load this loadout
## (MatchController._apply_loadout) so new cards can be TESTED. A standalone scene reached from the
## home-screen DECKS button — same pattern + Y2K theme as the Cosmetics scene. MENU ONLY — never the sim.
##
## SCOPE NOTE: this is the BASIC version (one active card per slot). The full 15-card deck + in-round
## cooldown-cycle "draw" is Content Engine P3 — see Wizard_Dodgeball_Brain/CONTENT_ENGINE.md §4.
extends Control

const HOME_SCENE := "res://scenes/home_screen.tscn"
const UI_THEME := preload("res://ui/main_theme.tres")

# {type:int, title:String} — type mirrors CardResource.CardType (ATTACK=0, DEFENSE=1, COUNTER=2).
const _SECTIONS: Array = [
	{"type": 0, "title": "ATTACK"},
	{"type": 1, "title": "DEFENSE"},
	{"type": 2, "title": "COUNTER"},
]

var _pp: Node
# type -> { id -> Y2KButton }, so a pick can re-highlight the active card in its section.
var _card_buttons: Dictionary = {}


func _ready() -> void:
	theme = UI_THEME
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_pp = get_node_or_null(^"/root/PlayerProfile")
	_build_background()
	_build_ui()
	_refresh_all()


func _build_background() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.08, 0.13)   # deep night-blue — the Y2K menu mood
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _build_ui() -> void:
	var title := _lbl("DECKS", Vector2(0, 110), Vector2(1080, 110), 84, HORIZONTAL_ALIGNMENT_CENTER)
	title.theme_type_variation = &"TitleLabel"
	add_child(title)

	var sub := _lbl("Tap a card to slot it. Offline matches use this loadout.",
		Vector2(80, 226), Vector2(920, 64), 28, HORIZONTAL_ALIGNMENT_CENTER)
	sub.theme_type_variation = &"MutedLabel"
	add_child(sub)

	var y: float = 332.0
	for section in _SECTIONS:
		y = _build_section(int(section["type"]), String(section["title"]), y)

	var back := _btn("◄ BACK", Vector2(80, 1748), Vector2(320, 104), 40)
	back.pressed.connect(func() -> void: _click(); get_tree().change_scene_to_file(HOME_SCENE))
	add_child(back)


func _build_section(card_type: int, title: String, y: float) -> float:
	var header := _lbl(title, Vector2(80, y), Vector2(920, 60), 44, HORIZONTAL_ALIGNMENT_LEFT)
	header.theme_type_variation = &"HeaderLabel"
	add_child(header)
	y += 80.0

	var bw: float = 280.0
	var bh: float = 150.0
	var gap: float = 16.0
	var x: float = 80.0
	var row_y: float = y
	var buttons: Dictionary = {}
	for id in CardCatalog.ids_of_type(card_type):
		var card: CardResource = CardCatalog.card_for(id)
		var label: String = String(id)
		if card != null and card.display_name != "":
			label = card.display_name
		var b := _btn(label, Vector2(x, row_y), Vector2(bw, bh), 30)
		var picked: StringName = id
		b.pressed.connect(func() -> void:
			_click()
			if _pp != null:
				_pp.set_active_card(card_type, picked)
			_refresh_section(card_type))
		add_child(b)
		buttons[id] = b
		x += bw + gap
		if x + bw > 1000.0:   # wrap to a new row if a type ever holds many cards
			x = 80.0
			row_y += bh + gap
	_card_buttons[card_type] = buttons
	return row_y + bh + 56.0


func _refresh_all() -> void:
	for section in _SECTIONS:
		_refresh_section(int(section["type"]))


func _refresh_section(card_type: int) -> void:
	if _pp == null:
		return
	var active: StringName = _pp.active_card_id(card_type)
	var buttons: Dictionary = _card_buttons.get(card_type, {})
	for id in buttons:
		var b: Control = buttons[id]
		b.modulate = Color(1.0, 0.84, 0.4) if StringName(id) == active else Color(1, 1, 1)


# =====================================================================
# UI helpers (mirror the Cosmetics scene — Y2K theme + Y2KButton)
# =====================================================================
func _btn(text: String, pos: Vector2, sz: Vector2, font_size: int) -> Y2KButton:
	var b := Y2KButton.new()
	b.text = text
	b.position = pos
	b.size = sz
	b.add_theme_font_size_override(&"font_size", font_size)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return b


func _lbl(text: String, pos: Vector2, sz: Vector2, font_size: int, align: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", font_size)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	l.text = text
	return l


func _click() -> void:
	var sfx := get_node_or_null(^"/root/SoundFX")
	if sfx != null and sfx.has_method(&"play"):
		sfx.play(&"ui_click")
