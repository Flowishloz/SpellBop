## decks.gd — the DECK BUILDER screen (Content Engine P4, full overhaul).
##
## Replaces the thin "one active card per slot" picker with a real two-state deck-building flow so MOVES
## can be eyeballed + tested clearly (CONTENT_ENGINE.md §13):
##
##   STATE 1 — "MY DECKS" (landing): the deck BOXES, hero-centred. One active deck + locked "purchasable
##             upgrade" slots (placeholder art). Tap the active box to edit.
##   STATE 2 — BUILDER: the active box tweens down into a bottom dock, revealing a split layout —
##             TOP 40% deck list (5 slots per type) · SEP 5% stats+filters · 40% inventory grid (rows of
##             3, scrollable) · BOTTOM 15% deck-box dock + Back.
##
## CARDS render in two variants: a SMALL tile (70% text / 30% art + an owned-quantity badge) used in the
## grid + deck list, and a BIG inspect modal (50/50, scales up over a darkened backdrop, tap-out to close).
##
## RULES (PlayerProfile is the single source of truth): a legal deck is 5 ATTACK + 5 DEFENSE + 5 COUNTER;
## copies of one card are capped by rarity (5 common / 2 uncommon / 1 rare). Adds clamp to that cap AND to
## how many you own; the quantity prompt shows the DYNAMIC cap. Rejections shake + buzz.
##
## DETERMINISM: this is 100% META (menu) state. Every edit goes through PlayerProfile (user://profile.cfg),
## which the sim NEVER reads mid-tick — the offline match only loads deck[type][0] at match start, headless-
## gated. Nothing here can touch the determinism sweep. MENU ONLY.
extends Control

const HOME_SCENE := "res://scenes/home_screen.tscn"
const UI_THEME := preload("res://ui/main_theme.tres")

# --- portrait layout bands (1080x1920), the 40 / 5 / 40 / 15 split from the design ---
const SCREEN := Vector2(1080.0, 1920.0)
const DECK_TOP := 24.0
const DECK_H := 744.0            # deck list region (~40%, minus the top safe margin)
const SEP_TOP := 768.0
const SEP_H := 96.0              # separator bar (~5%) — deck stats + type counts
const INV_TOP := 864.0
const INV_H := 768.0            # inventory region (~40%) — a filter strip + the scroll grid
const COLLECTION_H := 76.0       # the Collection header row (title + Filters button) at the top of the inventory band
const INV_MARGIN := 20.0         # symmetric L/R margin for the Collection grid
const SCROLLBAR_W := 18.0        # scrollbar reserve — lives in the right margin so the cards stay centred
const INV_CARD_H := 340.0        # full-card height in the Collection grid (rows of 3)
const BOTTOM_TOP := 1540.0       # deck-box dock — raised so the inventory grid isn't left with a big void
const BOTTOM_H := 380.0

const DOUBLE_MS := 260           # tap-vs-double-tap disambiguation window
const SCROLL_FRICTION := 4.0     # Collection flick-momentum decay (higher = stops sooner)
const SCROLL_MIN_VEL := 8.0      # px/s below which the flick stops

# Palettes — one source of truth. CARDS ARE COLOURED BY TYPE (CD: red=attack, green=defense, blue=counter),
# matching the in-match card (card_hand_hud.TYPE_COLORS). Faction stays a text attribute only.
const RARITY_COL := {0: Color(0.72, 0.77, 0.85), 1: Color(0.48, 0.86, 0.62), 2: Color(1.0, 0.81, 0.36)}    # COMMON/UNCOMMON/RARE
const RARITY_NAME := {0: "COMMON", 1: "UNCOMMON", 2: "RARE"}
const TYPE_COL := {0: Color(0.92, 0.36, 0.32), 1: Color(0.34, 0.78, 0.46), 2: Color(0.36, 0.6, 0.98)}      # ATTACK red / DEFENSE green / COUNTER blue
const TYPE_NAME := {0: "ATTACK", 1: "DEFENSE", 2: "COUNTER"}
const FACTION_NAME := {0: "RED", 1: "BLUE", 2: "GREEN"}
# The in-match card art (the actual icons the match HUD uses) — the FALLBACK glyph for a card that has
# no card_art yet (the BIG view's "as in a match" look).
const TYPE_ART := {0: "res://resources/placeholder/spark_icon.png", 1: "res://resources/placeholder/shield_icon.png", 2: "res://resources/placeholder/ice_icon.png"}

# --- Card Creation Engine: the UNIVERSAL frame assets (drop-in; every load is guarded so a missing file
#     is a graceful no-op until you add it). base_art is per-card (CardResource.card_art). The in-round
#     frame (border_in_round) is consumed by scenes/match_card_ui.tscn, not here. ---
const FRAME_DIR := "res://resources/cards/frames/"
const BORDER_PILL := FRAME_DIR + "border_pill.png"   # frames the small deck-list / inventory tile art well
const BORDER_FULL := FRAME_DIR + "border_full.png"   # frames the Big Inspect art well

var _pp: Node

# state
var _in_builder: bool = false
var _drag_type: int = -1         # the type being dragged (-1 = none) → focus-dims the other-type cards

# shared / persistent nodes
var _deck_box: DeckBoxIcon
var _landing: Control            # landing-only nodes (title, locked boxes, name, back)
var _builder: Control            # builder-only nodes (deck list, separator, inventory, dock)
var _overlay: Control            # modal layer (inspect / quantity), on top of everything

# landing — the editable deck-name widgets (a button that swaps to a LineEdit on click)
var _name_btn: Y2KButton
var _name_edit: LineEdit

# builder refs
var _deck_rows: VBoxContainer
var _inv_grid: GridContainer
var _stat_lbl: Label
var _type_counters: Array = [null, null, null]   # Label per type in the separator
var _type_row_nodes: Array = [null, null, null]  # the VBox per type row (for drag focus-dim)
var _toast_lbl: Label
var _dock_name_lbl: Label        # the deck name shown in the builder's bottom dock

# filters
var _filter_type: int = -1       # -1 = all
var _filter_rarity: int = -1     # -1 = all
var _search: String = ""
var _type_chip_btns: Array = []
var _rarity_chip_btns: Array = []
var _type_counter_btns: Array = []   # the separator's clickable type-count filters
var _filter_btn: Button              # opens the quick-filter popup
var _inv_scroll: ScrollContainer     # the Collection scroll (for swipe-pan + flick momentum)
var _scroll_vel: float = 0.0         # current flick velocity (px/s); decayed in _process
var _scroll_last: float = 0.0        # last frame's scroll_vertical (to measure live drag velocity)
var _scroll_dragging: bool = false   # true while a finger is actively panning the Collection


func _ready() -> void:
	theme = UI_THEME
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_pp = get_node_or_null(^"/root/PlayerProfile")
	_build_background()
	_build_landing()
	_build_builder()
	_build_deck_box()
	_build_overlay()
	_builder.visible = false
	_refresh()
	_apply_state(false, false)


# =====================================================================
# BACKGROUND
# =====================================================================
func _build_background() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.07, 0.12)      # deep night-blue (the Y2K menu mood)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# A faint lighter band behind the deck list so the builder split reads even before cards populate.
	var glow := ColorRect.new()
	glow.position = Vector2(0, 0)
	glow.size = Vector2(SCREEN.x, SEP_TOP)
	glow.color = Color(0.08, 0.11, 0.18, 0.5)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)


# =====================================================================
# STATE 1 — "MY DECKS" landing
# =====================================================================
func _build_landing() -> void:
	_landing = Control.new()
	_landing.set_anchors_preset(Control.PRESET_FULL_RECT)
	_landing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_landing)

	var back := _btn("‹  BACK", Vector2(40, SCREEN.y - 116), Vector2(220, 92), 34)   # bottom-left (matches the builder)
	back.pressed.connect(func() -> void: _click(); get_tree().change_scene_to_file(HOME_SCENE))
	_landing.add_child(back)

	var title := _lbl("MY DECKS", Vector2(60, 150), Vector2(960, 96), 72, HORIZONTAL_ALIGNMENT_CENTER)
	title.theme_type_variation = &"TitleLabel"
	_landing.add_child(title)

	var sub := _lbl("Tap your deck to build it. Locked slots are purchasable upgrades.",
		Vector2(80, 268), Vector2(920, 60), 28, HORIZONTAL_ALIGNMENT_CENTER)
	sub.theme_type_variation = &"MutedLabel"
	_landing.add_child(sub)

	# Two LOCKED "purchasable upgrade" deck slots flank the (hero-centred) active box (centres aligned at
	# y = 712). The active box itself is the shared _deck_box, built later + positioned over this centre.
	_landing.add_child(_make_locked_box(Vector2(90, 532)))
	_landing.add_child(_make_locked_box(Vector2(710, 532)))
	_landing.add_child(_locked_label(Vector2(90, 916)))
	_landing.add_child(_locked_label(Vector2(710, 916)))

	# Editable deck NAME under the active box — a button that swaps to a LineEdit on click.
	_name_btn = _btn("Deck 1  ✎", Vector2(370, 922), Vector2(340, 66), 34)
	_name_btn.show_cursor = false
	_name_btn.pressed.connect(_begin_rename)
	_landing.add_child(_name_btn)
	_name_edit = LineEdit.new()
	_name_edit.position = Vector2(370, 922)
	_name_edit.size = Vector2(340, 66)
	_name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_edit.max_length = 18
	_name_edit.add_theme_font_size_override(&"font_size", 34)
	_name_edit.visible = false
	_name_edit.text_submitted.connect(func(t: String) -> void: _commit_rename(t))
	_name_edit.focus_exited.connect(func() -> void: _commit_rename(_name_edit.text))
	_landing.add_child(_name_edit)


func _make_locked_box(pos: Vector2) -> DeckBoxIcon:
	var box := DeckBoxIcon.new()
	box.locked = true
	box.size = Vector2(280, 360)
	box.position = pos
	box.pivot_offset = box.size * 0.5
	box.screen = self
	box.modulate = Color(0.78, 0.82, 0.9, 0.9)
	return box


func _locked_label(box_pos: Vector2) -> Label:
	var l := _lbl("LOCKED", Vector2(box_pos.x, 916), Vector2(280, 50), 26, HORIZONTAL_ALIGNMENT_CENTER)
	l.theme_type_variation = &"MutedLabel"
	return l


# --- deck rename (landing) ---
func _begin_rename() -> void:
	_click()
	if _pp != null:
		_name_edit.text = String(_pp.deck_name)
	_name_btn.visible = false
	_name_edit.visible = true
	_name_edit.grab_focus()
	_name_edit.select_all()


func _commit_rename(text: String) -> void:
	if not _name_edit.visible:
		return   # focus_exited can fire twice (after text_submitted) — ignore the second
	if _pp != null:
		_pp.set_deck_name(text)
	_name_edit.visible = false
	_name_btn.visible = true
	_refresh_name()


func _refresh_name() -> void:
	if _pp == null:
		return
	if _name_btn != null:
		_name_btn.text = "%s  ✎" % String(_pp.deck_name)
	if _dock_name_lbl != null:
		_dock_name_lbl.text = String(_pp.deck_name)


# =====================================================================
# STATE 2 — BUILDER (deck list / separator / inventory / dock)
# =====================================================================
func _build_builder() -> void:
	_builder = Control.new()
	_builder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_builder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_builder)

	_build_deck_list_region()
	_build_separator()
	_build_inventory_region()
	_build_bottom_dock()
	_build_toast()


func _build_deck_list_region() -> void:
	var panel := _panel(Vector2(16, DECK_TOP), Vector2(SCREEN.x - 32, DECK_H), Color(0.09, 0.12, 0.19, 0.92))
	# The whole deck-list panel is the DROP TARGET — drop an inventory card anywhere here to add it.
	var drop := DropZone.new()
	drop.screen = self
	drop.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(drop)
	_builder.add_child(panel)

	var hdr := _lbl("ACTIVE DECK", Vector2(40, DECK_TOP + 14), Vector2(700, 50), 34, HORIZONTAL_ALIGNMENT_LEFT)
	hdr.theme_type_variation = &"HeaderLabel"
	_builder.add_child(hdr)
	var hint := _lbl("slot 1 of each type loads in offline matches",
		Vector2(40, DECK_TOP + 64), Vector2(900, 36), 23, HORIZONTAL_ALIGNMENT_LEFT)
	hint.theme_type_variation = &"MutedLabel"
	_builder.add_child(hint)

	# Three type rows (each: a header line + 5 fixed slots). Rebuilt by _refresh.
	_deck_rows = VBoxContainer.new()
	_deck_rows.position = Vector2(28, DECK_TOP + 112)
	_deck_rows.size = Vector2(SCREEN.x - 56, DECK_H - 124)
	_deck_rows.add_theme_constant_override(&"separation", 10)
	_deck_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_builder.add_child(_deck_rows)


func _build_separator() -> void:
	var bar := SepBar.new()
	bar.position = Vector2(0, SEP_TOP)
	bar.size = Vector2(SCREEN.x, SEP_H)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_builder.add_child(bar)

	# Left: total deck count. Right: the three coloured type counters.
	_stat_lbl = _lbl("DECK  0 / 15", Vector2(34, SEP_TOP + 18), Vector2(360, 60), 40, HORIZONTAL_ALIGNMENT_LEFT)
	_builder.add_child(_stat_lbl)

	# The three coloured counters are CLICKABLE type filters for the Collection (tap the active one to clear).
	var x := 470.0
	_type_counter_btns = []
	for t in 3:
		var ti := t
		var hit := Button.new()
		hit.flat = true
		hit.focus_mode = Control.FOCUS_NONE
		hit.position = Vector2(x - 6, SEP_TOP + 14)
		hit.size = Vector2(160, 64)
		hit.pressed.connect(func() -> void: _set_type_filter(ti))
		_builder.add_child(hit)
		var dot := TypeDot.new()
		dot.col = TYPE_COL[t]
		dot.position = Vector2(6, 16)
		dot.size = Vector2(36, 36)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hit.add_child(dot)
		var lbl := _lbl("0/5", Vector2(50, 4), Vector2(104, 56), 36, HORIZONTAL_ALIGNMENT_LEFT)
		lbl.modulate = TYPE_COL[t]
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hit.add_child(lbl)
		_type_counters[t] = lbl
		_type_counter_btns.append(hit)
		x += 200.0


func _build_inventory_region() -> void:
	# --- COLLECTION header (replaced the always-on filter strip): a title on the LEFT + a FILTERS button on
	#     the RIGHT that opens the quick-filter popup. The freed vertical space goes to a taller grid. ---
	var head := _lbl("COLLECTION", Vector2(28, INV_TOP + 10), Vector2(560, 56), 40, HORIZONTAL_ALIGNMENT_LEFT)
	head.theme_type_variation = &"HeaderLabel"
	_builder.add_child(head)
	_filter_btn = _btn("FILTERS", Vector2(SCREEN.x - 320, INV_TOP + 8), Vector2(292, 62), 28)
	_filter_btn.pressed.connect(_open_filter_popup)
	_builder.add_child(_filter_btn)

	# --- the scroll grid (rows of 3 full cards) — SYMMETRIC margins: the grid spans SCREEN-2*INV_MARGIN and
	#     the scrollbar reserve sits in the right margin, so the cards stay centred (fixes the L/R imbalance). ---
	var top := INV_TOP + COLLECTION_H
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(INV_MARGIN, top)
	scroll.size = Vector2(SCREEN.x - 2.0 * INV_MARGIN + SCROLLBAR_W, BOTTOM_TOP - top - 12)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_builder.add_child(scroll)
	_inv_scroll = scroll
	_inv_grid = GridContainer.new()
	_inv_grid.columns = 3
	_inv_grid.add_theme_constant_override(&"h_separation", 18)
	_inv_grid.add_theme_constant_override(&"v_separation", 18)
	scroll.add_child(_inv_grid)


func _build_bottom_dock() -> void:
	var dock := _panel(Vector2(0, BOTTOM_TOP), Vector2(SCREEN.x, BOTTOM_H), Color(0.03, 0.04, 0.07, 0.96))
	dock.mouse_filter = Control.MOUSE_FILTER_STOP   # the dark dock eats stray taps under the floating box
	_builder.add_child(dock)

	var back := _btn("‹  BACK", Vector2(36, BOTTOM_TOP + BOTTOM_H - 116), Vector2(220, 92), 32)
	back.pressed.connect(func() -> void: _click(); _apply_state(false, true))
	_builder.add_child(back)

	# Deck-slot swipe affordance (slot 1 active; 2 & 3 are locked upgrades) — flanking the docked box.
	var left := _arrow_btn(Vector2(300, BOTTOM_TOP + 92), -1)
	var right := _arrow_btn(Vector2(708, BOTTOM_TOP + 92), 1)
	_builder.add_child(left)
	_builder.add_child(right)
	_dock_name_lbl = _lbl("Deck 1", Vector2(360, BOTTOM_TOP + 22), Vector2(360, 48), 28, HORIZONTAL_ALIGNMENT_CENTER)
	_dock_name_lbl.theme_type_variation = &"MutedLabel"
	_builder.add_child(_dock_name_lbl)


func _build_toast() -> void:
	_toast_lbl = _lbl("", Vector2(140, SEP_TOP - 70), Vector2(800, 56), 32, HORIZONTAL_ALIGNMENT_CENTER)
	_toast_lbl.modulate = Color(1, 1, 1, 0)
	_builder.add_child(_toast_lbl)


func _build_deck_box() -> void:
	_deck_box = DeckBoxIcon.new()
	_deck_box.locked = false
	_deck_box.size = Vector2(280, 380)
	_deck_box.pivot_offset = _deck_box.size * 0.5
	_deck_box.screen = self
	add_child(_deck_box)


func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	add_child(_overlay)


# =====================================================================
# STATE TRANSITION (landing <-> builder; the deck box tweens between the two)
# =====================================================================
func _box_center(builder: bool) -> Vector2:
	return Vector2(540, BOTTOM_TOP + BOTTOM_H * 0.5) if builder else Vector2(540, 712)


func _apply_state(builder: bool, animate: bool) -> void:
	_in_builder = builder
	_close_overlay()
	var center := _box_center(builder)
	var box_pos := center - _deck_box.size * 0.5
	var box_scale := Vector2(0.62, 0.62) if builder else Vector2.ONE
	if animate:
		_click()
		# Cross-fade the two layers while the box slides + scales (all parallel from t=0).
		var appearing := _builder if builder else _landing
		var leaving := _landing if builder else _builder
		appearing.visible = true
		appearing.modulate = Color(1, 1, 1, 0)
		var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(_deck_box, "position", box_pos, 0.42)
		tw.tween_property(_deck_box, "scale", box_scale, 0.42)
		tw.tween_property(appearing, "modulate:a", 1.0, 0.34)
		tw.tween_property(leaving, "modulate:a", 0.0, 0.24)
		tw.tween_callback(func() -> void: leaving.visible = false; leaving.modulate = Color(1, 1, 1, 1)).set_delay(0.26)
	else:
		_deck_box.position = box_pos
		_deck_box.scale = box_scale
		_landing.visible = not builder
		_landing.modulate = Color(1, 1, 1, 1)
		_builder.visible = builder
		_builder.modulate = Color(1, 1, 1, 1)


## Called by the active deck box (DeckBoxIcon) when tapped.
func on_deck_box(box: DeckBoxIcon) -> void:
	if box.locked:
		_haptic(40)
		_toast("LOCKED  ·  PURCHASABLE UPGRADE", Color(1.0, 0.7, 0.4))
		_shake_pos(box)
		return
	if not _in_builder:
		_apply_state(true, true)


# =====================================================================
# REFRESH — deck list, inventory, stats
# =====================================================================
func _refresh() -> void:
	_rebuild_deck_list()
	_rebuild_inventory()
	_update_stats()
	_sync_chips()
	_refresh_type_counter_highlight()
	_refresh_name()


func _rebuild_deck_list() -> void:
	for c in _deck_rows.get_children():
		c.queue_free()
	if _pp == null:
		return
	for t in 3:
		var row := VBoxContainer.new()
		row.add_theme_constant_override(&"separation", 4)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var head := _lbl("%s   %d / %d" % [TYPE_NAME[t], _pp.type_count(t), PlayerProfileConst.PER_TYPE],
			Vector2.ZERO, Vector2(700, 30), 24, HORIZONTAL_ALIGNMENT_LEFT)
		head.modulate = TYPE_COL[t]
		row.add_child(head)

		var slots := HBoxContainer.new()
		slots.add_theme_constant_override(&"separation", 12)
		slots.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var list: Array = _pp.deck_list(t)
		var slot_w := (SCREEN.x - 56 - 12.0 * 4.0) / 5.0
		for i in PlayerProfileConst.PER_TYPE:
			if i < list.size():
				var tile := _make_tile(StringName(list[i]), &"deck", Vector2(slot_w, 150), i)
				slots.add_child(tile)
			else:
				var empty := EmptySlot.new()
				empty.custom_minimum_size = Vector2(slot_w, 150)
				empty.col = TYPE_COL[t]
				empty.mouse_filter = Control.MOUSE_FILTER_IGNORE   # drops fall through to the deck-list DropZone
				slots.add_child(empty)
		row.add_child(slots)
		_deck_rows.add_child(row)
		_type_row_nodes[t] = row
	# If a drag is in progress while the list rebuilds (after a drop), re-apply the focus dim.
	if _drag_type >= 0:
		_apply_drag_focus(true)


func _rebuild_inventory() -> void:
	for c in _inv_grid.get_children():
		c.queue_free()
	if _pp == null:
		return
	# 3 columns + 2 gaps fill the symmetric content width (matches the scroll above — fixes the L/R imbalance).
	var col_w := (SCREEN.x - 2.0 * INV_MARGIN - 2.0 * 18.0) / 3.0
	for id in CardCatalog.all_ids():
		var e := CardCatalog.entry_for(id)
		if e.is_empty():
			continue
		if _filter_type >= 0 and int(e["type"]) != _filter_type:
			continue
		if _filter_rarity >= 0 and int(e["rarity"]) != _filter_rarity:
			continue
		if _search != "":
			var card := CardCatalog.card_for(id)
			var nm := (card.display_name if card != null and card.display_name != "" else String(id)).to_lower()
			if not (nm.contains(_search) or String(id).contains(_search)):
				continue
		_inv_grid.add_child(_make_tile(id, &"inventory", Vector2(col_w, INV_CARD_H), -1))


func _update_stats() -> void:
	if _pp == null:
		return
	var total: int = _pp.total_count()
	_stat_lbl.text = "DECK  %d / 15" % total
	_stat_lbl.modulate = Color(0.55, 1.0, 0.6) if _pp.is_deck_complete() else Color(1, 1, 1)
	for t in 3:
		var lbl: Label = _type_counters[t]
		if lbl != null:
			lbl.text = "%d/5" % _pp.type_count(t)


func _sync_chips() -> void:
	for entry in _type_chip_btns:
		if is_instance_valid(entry["btn"]):
			(entry["btn"] as Button).button_pressed = (int(entry["v"]) == _filter_type)
	for entry2 in _rarity_chip_btns:
		if is_instance_valid(entry2["btn"]):
			(entry2["btn"] as Button).button_pressed = (int(entry2["v"]) == _filter_rarity)


## Click a separator type counter → toggle that type filter (click the active one again to clear).
func _set_type_filter(t: int) -> void:
	_click()
	_filter_type = -1 if _filter_type == t else t
	_sync_chips()
	_refresh_type_counter_highlight()
	_rebuild_inventory()


## Dim the non-selected type counters when a type filter is active (all bright when off).
func _refresh_type_counter_highlight() -> void:
	for t in 3:
		if t >= _type_counter_btns.size():
			continue
		var btn: Control = _type_counter_btns[t]
		if btn == null:
			continue
		var on := (_filter_type < 0) or (_filter_type == t)
		create_tween().set_trans(Tween.TRANS_SINE).tween_property(btn, "modulate", Color(1, 1, 1, 1.0 if on else 0.4), 0.15)


## The quick-filter popup (opened by the Collection FILTERS button): search + type + rarity chips.
func _open_filter_popup() -> void:
	_click()
	_open_overlay()
	var sz := Vector2(880, 660)
	var panel := Panel.new()
	panel.size = sz
	panel.position = (SCREEN - sz) * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.13, 0.20, 1.0)
	sb.set_corner_radius_all(24)
	sb.set_border_width_all(3)
	sb.border_color = Color(0.55, 0.82, 1.0, 0.9)
	panel.add_theme_stylebox_override(&"panel", sb)
	_overlay.add_child(panel)

	var title := _lbl("FILTERS", Vector2(40, 28), Vector2(sz.x - 80, 56), 40, HORIZONTAL_ALIGNMENT_LEFT)
	title.theme_type_variation = &"HeaderLabel"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(title)

	var search := LineEdit.new()
	search.placeholder_text = "Search cards…"
	search.text = _search
	search.position = Vector2(40, 104)
	search.size = Vector2(sz.x - 80, 64)
	search.add_theme_font_size_override(&"font_size", 30)
	search.text_changed.connect(func(t: String) -> void: _search = t.strip_edges().to_lower(); _rebuild_inventory())
	panel.add_child(search)

	var tl := _lbl("TYPE", Vector2(40, 196), Vector2(300, 34), 26, HORIZONTAL_ALIGNMENT_LEFT)
	tl.theme_type_variation = &"MutedLabel"
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tl)
	var trow := HBoxContainer.new()
	trow.position = Vector2(40, 234)
	trow.add_theme_constant_override(&"separation", 12)
	trow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(trow)
	_type_chip_btns = []
	for spec in [[-1, "ALL"], [0, "ATK"], [1, "DEF"], [2, "CTR"]]:
		var b := _chip(String(spec[1]), 150)
		var ft := int(spec[0])
		b.pressed.connect(func() -> void: _click(); _filter_type = ft; _sync_chips(); _refresh_type_counter_highlight(); _rebuild_inventory())
		trow.add_child(b)
		_type_chip_btns.append({"btn": b, "v": ft})

	var rl := _lbl("RARITY", Vector2(40, 338), Vector2(300, 34), 26, HORIZONTAL_ALIGNMENT_LEFT)
	rl.theme_type_variation = &"MutedLabel"
	rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(rl)
	var rrow := HBoxContainer.new()
	rrow.position = Vector2(40, 376)
	rrow.add_theme_constant_override(&"separation", 12)
	rrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(rrow)
	_rarity_chip_btns = []
	for spec2 in [[-1, "ALL"], [0, "C"], [1, "U"], [2, "R"]]:
		var b2 := _chip(String(spec2[1]), 140)
		var fr := int(spec2[0])
		if fr >= 0:
			b2.add_theme_color_override(&"font_color", RARITY_COL[fr])
		b2.pressed.connect(func() -> void: _click(); _filter_rarity = fr; _sync_chips(); _rebuild_inventory())
		rrow.add_child(b2)
		_rarity_chip_btns.append({"btn": b2, "v": fr})

	_sync_chips()

	var clear := _btn("CLEAR", Vector2(40, sz.y - 104), Vector2(sz.x * 0.5 - 60, 84), 32)
	clear.pressed.connect(func() -> void:
		_filter_type = -1
		_filter_rarity = -1
		_search = ""
		search.text = ""
		_sync_chips()
		_refresh_type_counter_highlight()
		_rebuild_inventory())
	panel.add_child(clear)
	var done := _btn("DONE", Vector2(sz.x * 0.5 + 20, sz.y - 104), Vector2(sz.x * 0.5 - 60, 84), 32)
	done.pressed.connect(func() -> void: _close_overlay())
	panel.add_child(done)


# =====================================================================
# TILE CALLBACKS (from CardTile / DropZone)
# =====================================================================
func _make_tile(id: StringName, context: StringName, sz: Vector2, slot_index: int) -> CardTile:
	var card := CardCatalog.card_for(id)
	var e := CardCatalog.entry_for(id)
	var ftype := int(e.get("type", 0)) if not e.is_empty() else 0
	var rarity := int(e.get("rarity", 0)) if not e.is_empty() else 0
	var t := CardTile.new()
	# Inner classes can't read outer-script consts/methods — feed everything in (the cosmetics.gd pattern).
	t.screen = self
	t.id = id
	t.card = card
	t.context = context
	t.full = (context == &"inventory")   # Collection cards render as full vertical cards (not pills)
	t.scroll = _inv_scroll if context == &"inventory" else null   # swipe-to-pan + flick momentum
	t.slot_index = slot_index
	t.ftype = ftype
	t.type_col = TYPE_COL[ftype]   # CARDS ARE COLOURED BY TYPE (red attack / green defense / blue counter)
	t.rarity_col = RARITY_COL[rarity]
	t.rarity = rarity
	t.title = card.display_name if card != null and card.display_name != "" else String(id)
	t.short_stats = _short_stats(card) if card != null else ""
	t.owned = _pp.owned_count(id) if _pp != null else 0
	t.card_art = card.card_art if card != null else null   # raw illustration (CardResource.card_art)
	t.border_tex = _frame_tex(BORDER_PILL)                  # universal pill frame (null until the asset exists)
	t.custom_minimum_size = sz
	t.size = sz
	t.build()
	return t


func on_tap(tile: CardTile) -> void:
	_open_inspect(tile.id, tile.context, tile.slot_index)


func on_double(tile: CardTile) -> void:
	if tile.context == &"inventory":
		_open_quantity(tile.id)
	else:
		_remove_one(tile.id)


func on_badge(tile: CardTile) -> void:
	if tile.context == &"inventory":
		_open_quantity(tile.id)


func begin_drag(tile: CardTile) -> void:
	_haptic(8)
	_click()
	_drag_type = tile.ftype
	_apply_drag_focus(true)


## Focus-pull: while a card is being dragged, dim + desaturate every card NOT of its type (deck rows +
## inventory) in a smooth tween, so the legal slots stand out. Restored on drag end.
func _apply_drag_focus(active: bool) -> void:
	var dim := Color(0.4, 0.42, 0.5, 0.42)
	for t in 3:
		var row: Control = _type_row_nodes[t]
		if row != null:
			var target := Color(1, 1, 1, 1) if (not active or t == _drag_type) else dim
			create_tween().set_trans(Tween.TRANS_SINE).tween_property(row, "modulate", target, 0.18)
	if _inv_grid != null:
		for child in _inv_grid.get_children():
			var ct := child as CardTile
			if ct != null:
				var target2 := Color(1, 1, 1, 1) if (not active or ct.ftype == _drag_type) else dim
				create_tween().set_trans(Tween.TRANS_SINE).tween_property(ct, "modulate", target2, 0.18)


func _notification(what: int) -> void:
	# Drag-end fires on BOTH a successful drop and a cancel — always lift the focus dim.
	if what == NOTIFICATION_DRAG_END:
		_drag_type = -1
		_apply_drag_focus(false)


# =====================================================================
# COLLECTION SCROLL MOMENTUM — a CardTile pans _inv_scroll directly during a swipe; here we measure that
# live velocity and, after the finger lifts, glide it to a stop (flick). scroll_stop() kills it (tap-to-stop).
# =====================================================================
func scroll_begin() -> void:
	if _inv_scroll == null:
		return
	_scroll_dragging = true
	_scroll_vel = 0.0
	_scroll_last = float(_inv_scroll.scroll_vertical)


func scroll_end() -> void:
	_scroll_dragging = false   # _process now decays the captured velocity (momentum)


func scroll_stop() -> void:
	_scroll_vel = 0.0
	_scroll_dragging = false


func _process(delta: float) -> void:
	if _inv_scroll == null:
		return
	if _scroll_dragging:
		# live drag — track velocity from the position the CardTile is panning.
		var inst := (float(_inv_scroll.scroll_vertical) - _scroll_last) / maxf(delta, 0.0001)
		_scroll_vel = lerpf(_scroll_vel, inst, 0.35)
		_scroll_last = float(_inv_scroll.scroll_vertical)
	elif absf(_scroll_vel) > SCROLL_MIN_VEL:
		# flick — glide + decay; stop dead at the top/bottom bound.
		var before := _inv_scroll.scroll_vertical
		_inv_scroll.scroll_vertical = int(round(float(before) + _scroll_vel * delta))
		if _inv_scroll.scroll_vertical == before:
			_scroll_vel = 0.0
		else:
			_scroll_vel *= exp(-SCROLL_FRICTION * delta)
			if absf(_scroll_vel) <= SCROLL_MIN_VEL:
				_scroll_vel = 0.0
		_scroll_last = float(_inv_scroll.scroll_vertical)


## Drag onto a FILLED slot → replace that card (same-type only; the dim guides this). Rejects if illegal.
func request_replace(card_type: int, index: int, id: StringName) -> void:
	if _pp == null:
		return
	if _pp.replace_at(card_type, index, id):
		_haptic(12)
		_click()
		_refresh()
	else:
		_reject(id, null)


## The drag preview — a compact, type-tinted CARD (not a text bar) CENTRED on the finger so it tracks the
## touch instead of trailing a corner behind it (request: smooth pick-up). Returned to force_drag.
func make_drag_preview(card: CardResource, id: StringName) -> Control:
	var e := CardCatalog.entry_for(id)
	var ftype := int(e.get("type", 0)) if not e.is_empty() else 0
	var rarity := int(e.get("rarity", 0)) if not e.is_empty() else 0
	var tcol: Color = TYPE_COL[ftype]
	var sz := Vector2(260, 120)
	var root := Control.new()                 # Godot pins root's origin to the finger
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var face := Panel.new()
	face.size = sz
	face.position = Vector2(-sz.x * 0.5, -sz.y * 0.5 - 18)   # centred + lifted a touch above the finger
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(tcol.r * 0.18 + 0.06, tcol.g * 0.18 + 0.07, tcol.b * 0.18 + 0.10, 0.98)
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(3)
	sb.border_color = tcol
	face.add_theme_stylebox_override(&"panel", sb)
	root.add_child(face)
	# art well (left ~32%) — card_art or the type-glyph fallback
	var well := Control.new()
	well.position = Vector2(12, 12)
	well.size = Vector2(sz.x * 0.32, sz.y - 24)
	well.clip_contents = true
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(well)
	if card != null and card.card_art != null:
		var tex := TextureRect.new()
		tex.texture = card.card_art
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		well.add_child(tex)
	else:
		var glyph := TypeGlyphIcon.new()
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.card_type = ftype
		glyph.tint = tcol.lightened(0.3)
		well.add_child(glyph)
	# name (right of the art; reserve the rarity corner)
	var nx := sz.x * 0.32 + 22
	var name_lbl := _lbl(card.display_name if card != null and card.display_name != "" else String(id),
		Vector2(nx, 12), Vector2(sz.x - nx - 44, sz.y - 24), 26, HORIZONTAL_ALIGNMENT_LEFT)
	name_lbl.modulate = tcol.lightened(0.45)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(name_lbl)
	# rarity (top-right)
	var rar := RarityIcon.new()
	rar.rarity = rarity
	rar.size = Vector2(30, 30)
	rar.position = Vector2(sz.x - 38, 8)
	face.add_child(rar)
	root.modulate = Color(1, 1, 1, 0.96)
	return root


## A drag (or the deck-list drop) requests adding `n` of `id`. Adds what's allowed; rejects with feedback.
func request_add(id: StringName, n: int, src: Control) -> void:
	if _pp == null:
		return
	var added: int = _pp.add_card(id, n)
	if added > 0:
		_haptic(12)
		_click()
		_refresh()
	else:
		_reject(id, src)


func _remove_one(id: StringName) -> void:
	if _pp != null and _pp.remove_card(id):
		_haptic(10)
		_click()
		_refresh()


# =====================================================================
# REJECTION feedback (shake + buzz + reason toast)
# =====================================================================
func _reject(id: StringName, src: Control) -> void:
	_haptic(45)
	var e := CardCatalog.entry_for(id)
	var reason := "CAN'T ADD"
	if not e.is_empty():
		var t := int(e["type"])
		var rarity := int(e["rarity"])
		if _pp.type_count(t) >= PlayerProfileConst.PER_TYPE:
			reason = "%s FULL  ·  5 / 5" % TYPE_NAME[t]
		elif _pp.count_in_deck(id) >= _pp.copy_limit(id):
			reason = "MAX %d  ·  %s LIMIT" % [_pp.copy_limit(id), RARITY_NAME[rarity]]
		elif _pp.owned_count(id) - _pp.count_in_deck(id) <= 0:
			reason = "YOU OWN ONLY %d" % _pp.owned_count(id)
		# shake the offending type counter
		var lbl: Label = _type_counters[t]
		if lbl != null:
			_shake_pos(lbl)
	_toast(reason, Color(1.0, 0.42, 0.4))
	if src != null:
		_flash_reject(src)


# =====================================================================
# BIG INSPECT MODAL (50/50, scales up over a darkened backdrop, tap-out to close)
# =====================================================================
func _open_inspect(id: StringName, context: StringName, slot_index: int) -> void:
	var card := CardCatalog.card_for(id)
	if card == null:
		return
	_click()
	_open_overlay()
	var e := CardCatalog.entry_for(id)
	var rarity := int(e["rarity"]) if not e.is_empty() else 0
	var ftype := int(e["type"]) if not e.is_empty() else 0

	var tcol: Color = TYPE_COL[ftype]

	# --- the CARD FACE, built to read like the in-match card (card_hand_hud MTG frame: gold border,
	#     type-coloured header, art icon, two bordered text boxes). clip_contents = true so NO text ever
	#     spills past the card border (request: reactive containment). ---
	var face_sz := Vector2(SCREEN.x * 0.80, SCREEN.y * 0.64)   # ~75% of the screen
	var W := face_sz.x
	var H := face_sz.y
	var m := 22.0
	var face := Panel.new()
	face.size = face_sz
	face.position = Vector2((SCREEN.x - W) * 0.5, (SCREEN.y - H) * 0.5 - 20)
	face.pivot_offset = face_sz * 0.5
	face.clip_contents = true
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0.09, 0.09, 0.13, 0.99)
	fsb.set_corner_radius_all(18)
	fsb.set_border_width_all(3)
	fsb.border_color = Color(0.8, 0.75, 0.6, 0.9)   # the match card's gold frame
	face.add_theme_stylebox_override(&"panel", fsb)
	_overlay.add_child(face)

	# header strip (type colour) with the card NAME
	var header := ColorRect.new()
	header.color = tcol
	header.position = Vector2(m, m)
	header.size = Vector2(W - 2 * m, 92)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(header)
	var name_lbl := _lbl((card.display_name if card.display_name != "" else String(id)).to_upper(),
		Vector2(m + 14, m), Vector2(W - 2 * m - 28, 92), 40, HORIZONTAL_ALIGNMENT_CENTER)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(name_lbl)

	# art well — the RAW card_art (cover-filled + cropped) under the universal border_full frame (Card
	# Creation Engine). No art yet → the procedural TYPE GLYPH fallback. No PNG yet → the procedural gold
	# placeholder border. Geometry UNCHANGED (art_y / art_h identical — no spacing touched).
	var art_y := m + 104.0
	var art_h := H * 0.40   # bigger art well (Phase 2) — also tightens Panel B, which fills down to the buttons
	var well_pos := Vector2(m, art_y)
	var well_sz := Vector2(W - 2 * m, art_h)
	face.add_child(_info_box(well_pos, well_sz, Color(0.05, 0.06, 0.09, 0.96)))   # dark backdrop
	var well := Control.new()
	well.position = well_pos
	well.size = well_sz
	well.clip_contents = true   # crop the COVER-filled art to the well
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(well)
	if card.card_art != null:
		var art := TextureRect.new()
		art.set_anchors_preset(Control.PRESET_FULL_RECT)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.texture = card.card_art
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		well.add_child(art)
	else:
		var glyph := TypeGlyphIcon.new()
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.card_type = ftype
		glyph.tint = tcol.lightened(0.3)
		well.add_child(glyph)
	var bfull := _frame_tex(BORDER_FULL)
	if bfull != null:
		var frame := TextureRect.new()
		frame.texture = bfull
		frame.position = well_pos
		frame.size = well_sz
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_SCALE
		frame.modulate = tcol   # tint the grayscale frame by Card Type
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		face.add_child(frame)
	else:
		var phb := PlaceholderBorder.new()
		phb.modulate = tcol      # tint the procedural placeholder by Card Type
		phb.position = well_pos
		phb.size = well_sz
		face.add_child(phb)

	# panel A — TYPE • DMG line + rarity · faction (MTG text box)
	var pa_y := art_y + art_h + 12
	face.add_child(_info_box(Vector2(m, pa_y), Vector2(W - 2 * m, 92), Color(0.13, 0.12, 0.1, 0.97)))
	var dmg: int = card.damage
	var line1 := ("%s    •    DMG %d" % [TYPE_NAME[ftype], dmg]) if dmg > 0 else ("%s    •    NO DMG" % TYPE_NAME[ftype])
	var a1 := _lbl(line1, Vector2(m + 16, pa_y + 8), Vector2(W - 2 * m - 32, 40), 30, HORIZONTAL_ALIGNMENT_LEFT)
	a1.modulate = tcol.lightened(0.4)
	a1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(a1)
	var a2 := _lbl("%s  ·  %s faction" % [RARITY_NAME[rarity], _faction_name(int(card.faction))],
		Vector2(m + 16, pa_y + 50), Vector2(W - 2 * m - 32, 34), 23, HORIZONTAL_ALIGNMENT_LEFT)
	a2.modulate = RARITY_COL[rarity]
	a2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(a2)

	# RARITY indicator — middle-right, on the line between the art-well bottom and the rules-box top
	# (procedural placeholder shape).
	var rar := RarityIcon.new()
	rar.rarity = rarity
	rar.size = Vector2(52, 52)
	rar.position = Vector2(W - m - 60, pa_y + 20)
	face.add_child(rar)

	# panel B — rules text + the full stat line (autowrap + clip_contents → always contained)
	var btn_h := 88.0
	var pb_y := pa_y + 104
	var pb_h := H - pb_y - m - btn_h - 14
	var panel_b := _info_box(Vector2(m, pb_y), Vector2(W - 2 * m, pb_h), Color(0.13, 0.12, 0.1, 0.97))
	panel_b.clip_contents = true
	face.add_child(panel_b)
	var body := _lbl(card.description + "\n\n— " + "  ·  ".join(_full_stats(card)),
		Vector2(10, 8), Vector2(W - 2 * m - 20, pb_h - 16), 25, HORIZONTAL_ALIGNMENT_LEFT)
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	body.autowrap_mode = TextServer.AUTOWRAP_WORD              # clean word wrap (no mid-word breaks)
	body.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS   # … instead of a hard clip
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_b.add_child(body)

	# action buttons, integrated at the bottom of the card
	var bw := W - 2 * m
	var by := H - m - btn_h
	if context == &"inventory":
		var add := _btn("ADD TO DECK", Vector2(m, by), Vector2(bw * 0.6 - 8, btn_h), 32)
		add.pressed.connect(func() -> void: request_add(id, 1, null))
		face.add_child(add)
		var many := _btn("×  MANY", Vector2(m + bw * 0.6 + 8, by), Vector2(bw * 0.4 - 8, btn_h), 30)
		many.pressed.connect(func() -> void: _close_overlay(); _open_quantity(id))
		face.add_child(many)
	elif slot_index != 0:
		var rem := _btn("REMOVE", Vector2(m, by), Vector2(bw * 0.46 - 8, btn_h), 32)
		rem.pressed.connect(func() -> void: _close_overlay(); _remove_one(id))
		face.add_child(rem)
		var act := _btn("LOAD IN MATCH", Vector2(m + bw * 0.46 + 8, by), Vector2(bw * 0.54 - 8, btn_h), 28)
		act.pressed.connect(func() -> void:
			_click()
			if _pp.make_active(id):
				_haptic(12); _refresh()
			_close_overlay())
		face.add_child(act)
	else:
		var rem2 := _btn("REMOVE", Vector2(m, by), Vector2(bw, btn_h), 32)
		rem2.pressed.connect(func() -> void: _close_overlay(); _remove_one(id))
		face.add_child(rem2)

	# pop-in scale
	face.scale = Vector2(0.72, 0.72)
	create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).tween_property(face, "scale", Vector2.ONE, 0.2)
	_haptic(8)


# =====================================================================
# QUANTITY PROMPT (dynamic cap = min(owned, rarity-limit, free type slots))
# =====================================================================
func _open_quantity(id: StringName) -> void:
	if _pp == null:
		return
	var card := CardCatalog.card_for(id)
	var max_add: int = _pp.max_addable(id)
	if max_add <= 0:
		_reject(id, null)
		return
	_click()
	_open_overlay()
	var e := CardCatalog.entry_for(id)
	var rarity := int(e["rarity"]) if not e.is_empty() else 0

	var sz := Vector2(780, 560)
	var panel := Panel.new()
	panel.size = sz
	panel.position = (SCREEN - sz) * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.13, 0.20, 1.0)
	sb.set_corner_radius_all(24)
	sb.set_border_width_all(3)
	sb.border_color = Color(0.55, 0.82, 1.0, 0.9)
	panel.add_theme_stylebox_override(&"panel", sb)
	_overlay.add_child(panel)

	var title := _lbl((card.display_name if card != null and card.display_name != "" else String(id)).to_upper(),
		Vector2(36, 34), Vector2(sz.x - 72, 60), 40, HORIZONTAL_ALIGNMENT_CENTER)
	title.theme_type_variation = &"HeaderLabel"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(title)
	var subtitle := _lbl("How many to add?   (max %d · %s limit)" % [max_add, RARITY_NAME[rarity]],
		Vector2(36, 104), Vector2(sz.x - 72, 44), 26, HORIZONTAL_ALIGNMENT_CENTER)
	subtitle.theme_type_variation = &"MutedLabel"
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(subtitle)

	# stepper  [ − ]   N / max   [ + ]
	var qty := {"n": 1}
	var count_lbl := _lbl("1 / %d" % max_add, Vector2(sz.x * 0.5 - 150, 200), Vector2(300, 110), 76, HORIZONTAL_ALIGNMENT_CENTER)
	count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(count_lbl)
	var minus := _btn("−", Vector2(70, 206), Vector2(110, 100), 56)
	minus.pressed.connect(func() -> void:
		qty["n"] = maxi(1, int(qty["n"]) - 1); count_lbl.text = "%d / %d" % [qty["n"], max_add]; _haptic(6); _click())
	panel.add_child(minus)
	var plus := _btn("+", Vector2(sz.x - 180, 206), Vector2(110, 100), 56)
	plus.pressed.connect(func() -> void:
		qty["n"] = mini(max_add, int(qty["n"]) + 1); count_lbl.text = "%d / %d" % [qty["n"], max_add]; _haptic(6); _click())
	panel.add_child(plus)

	var confirm := _btn("ADD", Vector2(40, sz.y - 116), Vector2(sz.x * 0.5 - 60, 92), 36)
	confirm.pressed.connect(func() -> void: _close_overlay(); request_add(id, int(qty["n"]), null))
	panel.add_child(confirm)
	var cancel := _btn("CANCEL", Vector2(sz.x * 0.5 + 20, sz.y - 116), Vector2(sz.x * 0.5 - 60, 92), 36)
	cancel.pressed.connect(func() -> void: _close_overlay())
	panel.add_child(cancel)


# =====================================================================
# OVERLAY plumbing (dark backdrop, tap-out to dismiss)
# =====================================================================
func _open_overlay() -> void:
	_close_overlay()
	_overlay.visible = true
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_close_overlay())
	_overlay.add_child(dim)
	create_tween().tween_property(dim, "color:a", 0.72, 0.2)


func _close_overlay() -> void:
	for c in _overlay.get_children():
		c.queue_free()
	_overlay.visible = false
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_type_chip_btns = []      # the filter popup's chips were just freed — drop the stale refs
	_rarity_chip_btns = []


# =====================================================================
# Feedback helpers (toast / shake / haptic)
# =====================================================================
func _toast(text: String, col: Color) -> void:
	if _toast_lbl == null:
		return
	_toast_lbl.text = text
	_toast_lbl.modulate = Color(col.r, col.g, col.b, 0)
	var tw := create_tween()
	tw.tween_property(_toast_lbl, "modulate:a", 1.0, 0.12)
	tw.tween_interval(1.1)
	tw.tween_property(_toast_lbl, "modulate:a", 0.0, 0.45)


## Position-shake for absolutely-placed nodes (type counters, locked boxes).
func _shake_pos(node: Control) -> void:
	var base := node.position
	var tw := create_tween()
	for dx in [16, -14, 11, -8, 5, 0]:
		tw.tween_property(node, "position:x", base.x + float(dx), 0.035)
	node.position = base


## Container-safe rejection flash for tiles (modulate + a quick scale wobble — never layout position).
func _flash_reject(node: Control) -> void:
	node.pivot_offset = node.size * 0.5
	var tw := create_tween().set_parallel(true)
	tw.tween_property(node, "modulate", Color(1.0, 0.4, 0.4), 0.08)
	tw.tween_property(node, "scale", Vector2(1.06, 1.06), 0.08)
	tw.chain().set_parallel(true)
	tw.tween_property(node, "modulate", Color(1, 1, 1), 0.18)
	tw.parallel().tween_property(node, "scale", Vector2.ONE, 0.18)


func _haptic(ms: int) -> void:
	# Mobile rumble; a safe no-op on desktop. Tied into pickups, drops, modal pops, and errors.
	Input.vibrate_handheld(ms)


# =====================================================================
# STAT formatting (what each move does, at a glance)
# =====================================================================
func _faction_name(f: int) -> String:
	match f:
		0: return "RED"
		1: return "BLUE"
		_: return "GREEN"


## A compact one-liner for the small tile.
func _short_stats(card: CardResource) -> String:
	match int(card.card_type):
		0:
			var s := "DMG %d · SPD %d" % [card.damage, int(card.base_speed)]
			if card.projectile_count > 1:
				s += " · x%d" % card.projectile_count
			if card.homing_strength > 0.0:
				s += " · HOMING"
			if card.barrier_breaker:
				s += " · BREAK"
			return s
		1:
			if card.buff_duration > 0.0:
				if card.move_speed_buff > 1.0:
					return "MOVE +%d%% · %ss" % [int(round((card.move_speed_buff - 1.0) * 100.0)), _secs(card.buff_duration)]
				if card.fireball_haste < 1.0:
					return "HASTE −%d%% · %ss" % [int(round((1.0 - card.fireball_haste) * 100.0)), _secs(card.buff_duration)]
				return "BUFF · %ss" % _secs(card.buff_duration)
			return "WALL %d · %ss · ↩×%s" % [int(card.wall_size.x), _secs(card.wall_lifetime), _secs(card.woa_max_reflect)]
		2:
			return "SLOW %ss · ×%s" % [_secs(card.slow_duration), _secs(card.slow_scale_strong)]
	return ""


## Full per-mechanic lines for the big inspect modal.
func _full_stats(card: CardResource) -> Array:
	var out: Array = []
	match int(card.card_type):
		0:
			out.append("DMG %d" % card.damage)
			out.append("SPEED %d" % int(card.base_speed))
			out.append("SIZE %d" % int(card.projectile_size))
			out.append("BOUNCE %s" % _secs(card.bounciness))
			if card.projectile_count > 1:
				out.append("SHOTS x%d" % card.projectile_count)
			if card.homing_strength > 0.0:
				out.append("HOMING %d%%" % int(round(card.homing_strength * 100.0)))
			if card.barrier_breaker:
				out.append("SHATTERS WALLS")
		1:
			if card.buff_duration > 0.0:
				out.append("BUFF %ss" % _secs(card.buff_duration))
				if card.move_speed_buff > 1.0:
					out.append("MOVE +%d%%" % int(round((card.move_speed_buff - 1.0) * 100.0)))
				if card.fireball_haste < 1.0:
					out.append("FIREBALL HASTE −%d%%" % int(round((1.0 - card.fireball_haste) * 100.0)))
				out.append("NO WALL")
			else:
				out.append("WALL %d×%d" % [int(card.wall_size.x), int(card.wall_size.y)])
				out.append("LASTS %ss" % _secs(card.wall_lifetime))
				out.append("REFLECT ×%s" % _secs(card.woa_max_reflect))
				if card.wall_movement_speed > 0.0:
					out.append("DRIFTS %d" % int(card.wall_movement_speed))
		2:
			out.append("SLOW %ss" % _secs(card.slow_duration))
			out.append("STRENGTH ×%s..×%s" % [_secs(card.slow_scale_strong), _secs(card.slow_scale_weak)])
			out.append("RETURN ×%s" % _secs(card.speed_modifier))
	return out


## Trim a float to a short string (1.5 -> "1.5", 3.0 -> "3").
func _secs(v: float) -> String:
	if absf(v - round(v)) < 0.05:
		return str(int(round(v)))
	return "%.1f" % v


# =====================================================================
# tiny builders (match the cosmetics / menu_flow code style)
# =====================================================================
func _btn(text: String, pos: Vector2, sz: Vector2, font_size: int) -> Y2KButton:
	var b := Y2KButton.new()
	b.text = text
	b.position = pos
	b.size = sz
	b.add_theme_font_size_override(&"font_size", font_size)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return b


func _chip(text: String, w: float) -> Button:
	var b := Y2KButton.new()
	b.text = text
	b.toggle_mode = true
	b.show_cursor = false
	b.custom_minimum_size = Vector2(w, 64)
	b.add_theme_font_size_override(&"font_size", 28)
	return b


func _panel(pos: Vector2, sz: Vector2, col: Color) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = sz
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.5, 0.6, 0.78, 0.4)
	p.add_theme_stylebox_override(&"panel", sb)
	return p


## A small bordered MTG-style text box (matches card_hand_hud._make_info_panel — the in-match card look).
func _info_box(pos: Vector2, sz: Vector2, bg: Color) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.78, 0.7, 0.5, 0.85)
	p.add_theme_stylebox_override(&"panel", sb)
	return p


func _lbl(text: String, pos: Vector2, sz: Vector2, font_size: int, align: int) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.size = sz
	l.add_theme_font_size_override(&"font_size", font_size)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _arrow_btn(pos: Vector2, dir: int) -> Y2KButton:
	var b := _btn("‹" if dir < 0 else "›", pos, Vector2(72, 96), 48)
	b.show_cursor = false
	b.pressed.connect(func() -> void:
		_haptic(40)
		_toast("DECK SLOT LOCKED  ·  UPGRADE", Color(1.0, 0.7, 0.4)))
	return b


func _click() -> void:
	var sfx := get_node_or_null(^"/root/SoundFX")
	if sfx != null and sfx.has_method(&"play"):
		sfx.play(&"ui_click")


## Load a universal frame texture (border_pill / border_full), or null if it isn't on disk yet — so the
## Card Creation Engine assembles gracefully BEFORE you drop the PNGs in. Drop-in safe.
func _frame_tex(path: String) -> Texture2D:
	return (load(path) as Texture2D) if ResourceLoader.exists(path) else null


# Tiny shim so the inner classes / row builder can read PlayerProfile's PER_TYPE without a hard dep.
class PlayerProfileConst:
	const PER_TYPE := 5


# =====================================================================
# CARD TILE — the SMALL variant (70% text / 30% art + owned-quantity badge).
# Drag source (inventory) + tap/double-tap/badge dispatch. context = &"inventory" | &"deck".
# =====================================================================
class CardTile extends Control:
	const DOUBLE_MS := 260
	const HOLD_MS := 150        # hold this long (still) before a move PICKS UP a Collection card (else = scroll)
	const MOVE_THRESH := 14.0   # px of movement that commits the gesture to scroll-or-drag
	var screen: Node
	var id: StringName
	var card: CardResource
	var context: StringName = &"inventory"
	var slot_index: int = -1
	# fed by _make_tile (inner classes can't read outer-script consts/methods — the cosmetics.gd pattern):
	var ftype: int = 0
	var type_col: Color = Color(0.6, 0.6, 0.7)
	var rarity_col: Color = Color(0.7, 0.74, 0.8)
	var rarity: int = 0               # rarity tier (drives the procedural rarity icon)
	var title: String = ""
	var short_stats: String = ""
	var owned: int = 0
	var card_art: Texture2D = null     # raw per-card illustration (CardResource.card_art)
	var border_tex: Texture2D = null   # universal border_pill frame (null until the asset exists)
	var full: bool = false             # Collection cards render as full vertical cards; deck-list = pill
	var scroll: ScrollContainer = null # the Collection ScrollContainer (inventory tiles) — for swipe-to-pan

	var _last_tap_ms: int = -10000
	# press/hold/swipe state (Collection tiles): mode 0 undecided · 1 scroll · 2 drag
	var _press_active: bool = false
	var _press_ms: int = 0
	var _moved: float = 0.0
	var _mode: int = 0


	func build() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		if full:
			_build_full()
			return
		_build_pill()


	# PILL variant (deck list): horizontal — art well left 30%, name + stats right 70%, frame over the whole
	# tile, rarity top-right, owned badge bottom-right.
	func _build_pill() -> void:
		# --- ART WELL (Card Creation Engine): raw card_art cropped to the left art well (geometry MATCHES
		#     the _draw art rect exactly — no spacing change). No art yet → the procedural type glyph in
		#     _draw is the fallback. The border_pill frame (WHOLE tile, Phase 2) is added after the text. ---
		var art_rect := Rect2(12, 10, size.x * 0.30 - 8, size.y - 20)
		if card_art != null:
			var well := Control.new()
			well.position = art_rect.position
			well.size = art_rect.size
			well.clip_contents = true   # crop the COVER-filled art to the well
			well.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(well)
			var tex := TextureRect.new()
			tex.texture = card_art
			tex.set_anchors_preset(Control.PRESET_FULL_RECT)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
			well.add_child(tex)
		var compact := size.x < 230.0   # the narrow deck-list slots scale their text down
		var name_fs := 18 if compact else 25

		# NAME only (Phase 2: the pill drops the shorthand-stats clutter — name + art + rarity only).
		# Right ~70%, vertically centred; the left 30% is the art well / glyph (drawn in _draw).
		var tx := size.x * 0.30 + 8
		var tw := size.x - tx - 10
		var name_lbl := Label.new()
		name_lbl.text = title
		name_lbl.position = Vector2(tx, 8)
		name_lbl.size = Vector2(tw - 42, size.y - 16)   # reserve the top-right rarity icon
		name_lbl.add_theme_font_size_override(&"font_size", name_fs)
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_lbl.modulate = type_col
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(name_lbl)

		# FRAME — the universal border_pill over the WHOLE tile (Phase 2), TINTED by Card Type via modulate
		# (the grayscale PNG / procedural placeholder become red/green/blue). On top of the art + name.
		if border_tex != null:
			var frame := TextureRect.new()
			frame.texture = border_tex
			frame.position = Vector2.ZERO
			frame.size = size
			frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			frame.stretch_mode = TextureRect.STRETCH_SCALE
			frame.modulate = type_col
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(frame)
		else:
			var ph := PlaceholderBorder.new()
			ph.modulate = type_col
			ph.position = Vector2.ZERO
			ph.size = size
			add_child(ph)

		# inventory tiles show the owned-qty badge (bottom-right) — on top of the frame.
		if context == &"inventory":
			_add_badge("x%d" % owned, Color(0.12, 0.16, 0.24, 0.95), Color(1, 1, 1), false)

		# RARITY indicator — TOP-right corner (procedural placeholder shape).
		var rsz := 28.0 if compact else 32.0
		var rar := RarityIcon.new()
		rar.rarity = rarity
		rar.size = Vector2(rsz, rsz)
		rar.position = Vector2(size.x - rsz - 8.0, 8.0)
		add_child(rar)


	# FULL variant (Collection): vertical — art on top (clipped), name + shorthand stats below, frame over the
	# whole card, rarity top-right, owned badge bottom-right.
	func _build_full() -> void:
		var pad := 12.0
		var art_h := size.y * 0.50
		var art_top := pad
		# ART (top) — cover-cropped + clipped; the type-glyph fallback is drawn in _draw_full.
		if card_art != null:
			var well := Control.new()
			well.position = Vector2(pad, art_top)
			well.size = Vector2(size.x - 2.0 * pad, art_h)
			well.clip_contents = true
			well.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(well)
			var tex := TextureRect.new()
			tex.texture = card_art
			tex.set_anchors_preset(Control.PRESET_FULL_RECT)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
			well.add_child(tex)
		# NAME (below the art)
		var name_lbl := Label.new()
		name_lbl.text = title
		name_lbl.position = Vector2(pad + 4, art_top + art_h + 4)
		name_lbl.size = Vector2(size.x - 2.0 * pad - 8, 38)
		name_lbl.add_theme_font_size_override(&"font_size", 24)
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
		name_lbl.clip_text = true
		name_lbl.modulate = type_col
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(name_lbl)
		# SHORTHAND STATS (bottom)
		var stat_top := art_top + art_h + 46
		var stat_lbl := Label.new()
		stat_lbl.text = short_stats
		stat_lbl.position = Vector2(pad + 4, stat_top)
		stat_lbl.size = Vector2(size.x - 2.0 * pad - 8, size.y - stat_top - pad - 4)
		stat_lbl.add_theme_font_size_override(&"font_size", 18)
		stat_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		stat_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		stat_lbl.modulate = Color(0.80, 0.85, 0.93)
		stat_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(stat_lbl)
		# FRAME — the universal border_pill over the WHOLE card, TINTED by Card Type via modulate.
		if border_tex != null:
			var frame := TextureRect.new()
			frame.texture = border_tex
			frame.position = Vector2.ZERO
			frame.size = size
			frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			frame.stretch_mode = TextureRect.STRETCH_SCALE
			frame.modulate = type_col
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(frame)
		else:
			var ph := PlaceholderBorder.new()
			ph.modulate = type_col
			ph.position = Vector2.ZERO
			ph.size = size
			add_child(ph)
		# owned badge (bottom-right) + RARITY (top-right)
		if context == &"inventory":
			_add_badge("x%d" % owned, Color(0.12, 0.16, 0.24, 0.95), Color(1, 1, 1), false)
		var rar := RarityIcon.new()
		rar.rarity = rarity
		rar.size = Vector2(40, 40)
		rar.position = Vector2(size.x - 40 - 12, 12)
		add_child(rar)


	func _add_badge(text: String, bg: Color, fg: Color, top: bool) -> void:
		var bw := 42.0 if top else 58.0
		var bh := 30.0 if top else 38.0
		var b := Panel.new()
		b.size = Vector2(bw, bh)
		b.position = Vector2(size.x - bw - 6, 6.0) if top else Vector2(size.x - bw - 6, size.y - bh - 6)
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.set_corner_radius_all(10)
		b.add_theme_stylebox_override(&"panel", sb)
		var l := Label.new()
		l.text = text
		l.set_anchors_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override(&"font_size", 22 if top else 24)
		l.modulate = fg
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(l)
		add_child(b)


	# The owned-qty badge hit-rect (bottom-right, inventory) — a tap here opens the quantity prompt.
	func _badge_rect() -> Rect2:
		return Rect2(size.x - 70, size.y - 50, 70, 50)


	func _draw() -> void:
		if full:
			_draw_full()
		else:
			_draw_pill()


	func _draw_pill() -> void:
		var fac := type_col
		var is_active := context == &"deck" and slot_index == 0   # the "loaded in match" slot
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(fac.r * 0.18 + 0.06, fac.g * 0.18 + 0.07, fac.b * 0.18 + 0.10, 0.96)
		sb.set_corner_radius_all(14)
		sb.set_border_width_all(4 if is_active else 2)
		# GOLD active border — stands out on ALL three type colours (green-on-green blended before).
		sb.border_color = Color(1.0, 0.84, 0.3, 1.0) if is_active else Color(fac.r, fac.g, fac.b, 0.5)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		# rarity stripe down the left edge
		draw_rect(Rect2(0, 8, 6, size.y - 16), rarity_col)
		# art panel (left 30%) + a type glyph
		var art := Rect2(12, 10, size.x * 0.30 - 8, size.y - 20)
		var asb := StyleBoxFlat.new()
		asb.bg_color = Color(fac.r * 0.30 + 0.04, fac.g * 0.30 + 0.05, fac.b * 0.30 + 0.08, 1.0)
		asb.set_corner_radius_all(10)
		draw_style_box(asb, art)
		# type glyph — FALLBACK only (the card_art TextureRect replaces it when art is assigned)
		if card_art == null:
			_draw_type_glyph(art, Color(fac.r, fac.g, fac.b, 0.95))


	func _draw_full() -> void:
		var fac := type_col
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(fac.r * 0.16 + 0.05, fac.g * 0.16 + 0.06, fac.b * 0.16 + 0.09, 0.96)
		sb.set_corner_radius_all(16)
		sb.set_border_width_all(2)
		sb.border_color = Color(fac.r, fac.g, fac.b, 0.45)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		# art-well backdrop (top half) + type-glyph fallback when no card_art
		var pad := 12.0
		var art := Rect2(pad, pad, size.x - 2.0 * pad, size.y * 0.50)
		var asb := StyleBoxFlat.new()
		asb.bg_color = Color(fac.r * 0.26 + 0.03, fac.g * 0.26 + 0.04, fac.b * 0.26 + 0.07, 1.0)
		asb.set_corner_radius_all(10)
		draw_style_box(asb, art)
		if card_art == null:
			_draw_type_glyph(art, Color(fac.r, fac.g, fac.b, 0.95))


	func _draw_type_glyph(rect: Rect2, col: Color) -> void:
		var c := rect.position + rect.size * 0.5
		var r := minf(rect.size.x, rect.size.y) * 0.30
		match ftype:
			0:  # ATTACK — lightning bolt
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(-r * 0.3, -r), c + Vector2(r * 0.45, -r * 0.15),
					c + Vector2(r * 0.05, -r * 0.15), c + Vector2(r * 0.4, r),
					c + Vector2(-r * 0.45, r * 0.1), c + Vector2(-r * 0.02, r * 0.1)]), col)
			1:  # DEFENSE — shield
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(0, -r * 1.1), c + Vector2(r, -r * 0.6), c + Vector2(r * 0.7, r * 0.5),
					c + Vector2(0, r * 1.1), c + Vector2(-r * 0.7, r * 0.5), c + Vector2(-r, -r * 0.6)]), col)
			_:  # COUNTER — frost diamond
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(0, -r), c + Vector2(r * 0.7, 0), c + Vector2(0, r), c + Vector2(-r * 0.7, 0)]), col)
				draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), col, 3.0)
				draw_line(c + Vector2(0, -r), c + Vector2(0, r), col, 3.0)


	func _get_drag_data(_pos: Vector2) -> Variant:
		return null   # drags are initiated by a long-press -> force_drag (see _gui_input), not auto-drag


	# A FILLED deck slot accepts a SAME-TYPE drop → REPLACE the card in that slot (the drag-dim guides you
	# to the legal slots). Empty slots / gaps fall through to the deck-list DropZone, which appends.
	func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
		if context != &"deck" or not (data is Dictionary and (data as Dictionary).has(&"id")):
			return false
		var de := CardCatalog.entry_for(StringName((data as Dictionary)[&"id"]))
		return not de.is_empty() and int(de["type"]) == ftype   # same type only

	func _drop_data(_pos: Vector2, data: Variant) -> void:
		if screen != null:
			screen.request_replace(ftype, slot_index, StringName((data as Dictionary)[&"id"]))


	func _gui_input(event: InputEvent) -> void:
		if not full:
			# deck-list pill: a simple tap / double-tap (no scroll, not a drag source).
			if event is InputEventMouseButton:
				var b := event as InputEventMouseButton
				if b.button_index == MOUSE_BUTTON_LEFT and not b.pressed:
					_handle_tap(b.position)
					accept_event()
			return
		# COLLECTION tile: TAP = inspect · HOLD-then-move = pick up + drag · quick SWIPE = scroll the grid.
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if scroll != null and mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				scroll.scroll_vertical -= 80
				accept_event()
				return
			if scroll != null and mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				scroll.scroll_vertical += 80
				accept_event()
				return
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			if mb.pressed:
				_press_active = true
				_press_ms = Time.get_ticks_msec()
				_moved = 0.0
				_mode = 0
				if screen != null:
					screen.scroll_stop()   # a new press kills any in-flight flick (tap-to-stop)
			else:
				if _press_active and _mode == 0 and _moved < MOVE_THRESH:
					_handle_tap(mb.position)
				elif _mode == 1 and screen != null:
					screen.scroll_end()    # hand the swipe velocity to the momentum glide
				_press_active = false
				_mode = 0
			accept_event()
		elif event is InputEventMouseMotion and _press_active:
			var mm := event as InputEventMouseMotion
			_moved += mm.relative.length()
			if _mode == 0 and _moved > MOVE_THRESH:
				# the FIRST real movement decides: a brief HOLD first -> pick up; a quick swipe -> scroll.
				if Time.get_ticks_msec() - _press_ms >= HOLD_MS:
					_mode = 2
					_begin_pickup()
				else:
					_mode = 1
					if screen != null:
						screen.scroll_begin()
			if _mode == 1 and scroll != null:
				scroll.scroll_vertical = scroll.scroll_vertical - int(mm.relative.y)
			accept_event()


	## Long-press pickup: start a native drag programmatically (bypasses _get_drag_data) with the card preview.
	func _begin_pickup() -> void:
		if screen == null:
			return
		screen.begin_drag(self)
		force_drag({&"id": id}, screen.make_drag_preview(card, id))


	## Resolve a tap: the owned-qty badge -> quantity prompt; else single (delayed) / double-tap dispatch.
	func _handle_tap(pos: Vector2) -> void:
		if screen == null:
			return
		if context == &"inventory" and _badge_rect().has_point(pos):
			screen.on_badge(self)
			return
		var now := Time.get_ticks_msec()
		if now - _last_tap_ms <= DOUBLE_MS:
			_last_tap_ms = -10000
			screen.on_double(self)
		else:
			_last_tap_ms = now
			var tok := now
			get_tree().create_timer(DOUBLE_MS / 1000.0).timeout.connect(func() -> void:
				if _last_tap_ms == tok and is_instance_valid(self):
					_last_tap_ms = -10000
					screen.on_tap(self))


	func _notification(what: int) -> void:
		if what == NOTIFICATION_DRAG_END:   # reset the press state so a post-drag hover can't mis-trigger
			_press_active = false
			_mode = 0


# =====================================================================
# CARD ART — a faction-tinted placeholder with a type glyph (no art assets yet; ui_sprite is unset).
# =====================================================================
class CardArt extends Control:
	var card: CardResource
	var faction: Color = Color(0.6, 0.6, 0.7)
	var ftype: int = 0


	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(faction.r * 0.30 + 0.04, faction.g * 0.30 + 0.05, faction.b * 0.30 + 0.08, 1.0)
		sb.set_corner_radius_all(10)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.30
		var bright := Color(faction.r, faction.g, faction.b, 0.95)
		match ftype:
			0:  # ATTACK — a lightning bolt
				var pts := PackedVector2Array([
					c + Vector2(-r * 0.3, -r), c + Vector2(r * 0.45, -r * 0.15),
					c + Vector2(r * 0.05, -r * 0.15), c + Vector2(r * 0.4, r),
					c + Vector2(-r * 0.45, r * 0.1), c + Vector2(-r * 0.02, r * 0.1)])
				draw_colored_polygon(pts, bright)
			1:  # DEFENSE — a shield
				var s := PackedVector2Array([
					c + Vector2(0, -r * 1.1), c + Vector2(r, -r * 0.6), c + Vector2(r * 0.7, r * 0.5),
					c + Vector2(0, r * 1.1), c + Vector2(-r * 0.7, r * 0.5), c + Vector2(-r, -r * 0.6)])
				draw_colored_polygon(s, bright)
			_:  # COUNTER — a frost diamond / star
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(0, -r), c + Vector2(r * 0.7, 0), c + Vector2(0, r), c + Vector2(-r * 0.7, 0)]), bright)
				draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), bright, 4.0)
				draw_line(c + Vector2(0, -r), c + Vector2(0, r), bright, 4.0)


# =====================================================================
# DROP ZONE — the deck-list panel accepts an inventory card drop (adds 1 to its type).
# =====================================================================
class DropZone extends Control:
	var screen: Node

	func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
		return data is Dictionary and (data as Dictionary).has(&"id")

	func _drop_data(_pos: Vector2, data: Variant) -> void:
		if screen != null:
			screen.request_add(StringName((data as Dictionary)[&"id"]), 1, null)


# =====================================================================
# EMPTY SLOT — a dashed placeholder for an unfilled deck slot.
# =====================================================================
class EmptySlot extends Control:
	var col: Color = Color(0.5, 0.6, 0.78)

	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.09, 0.14, 0.7)
		sb.set_corner_radius_all(12)
		sb.set_border_width_all(2)
		sb.border_color = Color(col.r, col.g, col.b, 0.28)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		var c := size * 0.5
		var s := 14.0
		draw_line(c + Vector2(-s, 0), c + Vector2(s, 0), Color(col.r, col.g, col.b, 0.4), 3.0)
		draw_line(c + Vector2(0, -s), c + Vector2(0, s), Color(col.r, col.g, col.b, 0.4), 3.0)


# =====================================================================
# SEPARATOR BAR — a horizontal bar with a 3D bevel (the anchor between deck list + inventory).
# =====================================================================
class SepBar extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.15, 0.22, 1.0))
		draw_rect(Rect2(0, 0, size.x, size.y * 0.45), Color(0.17, 0.21, 0.30, 1.0))   # top highlight band
		draw_line(Vector2(0, 1.5), Vector2(size.x, 1.5), Color(0.45, 0.6, 0.85, 0.9), 3.0)       # bright top edge
		draw_line(Vector2(0, size.y - 1.5), Vector2(size.x, size.y - 1.5), Color(0.0, 0.0, 0.0, 0.6), 3.0)  # dark bottom


# =====================================================================
# TYPE DOT — a small filled circle (the coloured type indicator in the stats bar).
# =====================================================================
class TypeDot extends Control:
	var col: Color = Color.WHITE
	func _draw() -> void:
		draw_circle(size * 0.5, minf(size.x, size.y) * 0.5, col)


# =====================================================================
# DECK BOX — the placeholder deck-box sprite (active or locked "upgrade" slot).
# =====================================================================
class DeckBoxIcon extends Control:
	var screen: Node
	var locked: bool = false


	func _draw() -> void:
		var accent := Color(0.55, 0.82, 1.0) if not locked else Color(0.45, 0.5, 0.62)
		# box body
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.11, 0.14, 0.22, 1.0) if not locked else Color(0.08, 0.09, 0.13, 1.0)
		sb.set_corner_radius_all(22)
		sb.set_border_width_all(3)
		sb.border_color = accent
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		# a stacked-cards motif on the lid
		var cx := size.x * 0.5
		for i in 3:
			var off := float(i) * 14.0 - 14.0
			var cw := size.x * 0.42
			var ch := size.y * 0.30
			var cr := Rect2(cx - cw * 0.5 + off, size.y * 0.16 + off * 0.6, cw, ch)
			var cs := StyleBoxFlat.new()
			cs.bg_color = Color(accent.r, accent.g, accent.b, 0.16 + 0.12 * float(i))
			cs.set_corner_radius_all(10)
			cs.set_border_width_all(2)
			cs.border_color = Color(accent.r, accent.g, accent.b, 0.6)
			draw_style_box(cs, cr)
		if locked:
			# padlock + label
			var pc := Vector2(size.x * 0.5, size.y * 0.66)
			draw_circle(pc, 26, Color(0, 0, 0, 0))
			var body := StyleBoxFlat.new()
			body.bg_color = accent
			body.set_corner_radius_all(6)
			draw_style_box(body, Rect2(pc.x - 26, pc.y - 6, 52, 40))
			draw_arc(pc + Vector2(0, -10), 16, PI, TAU, 16, accent, 6.0)


	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			if screen != null:
				screen.on_deck_box(self)
			accept_event()
