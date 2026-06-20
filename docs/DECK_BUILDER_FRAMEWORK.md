# Spell Bop — Deck Builder + Card Creation Engine Framework

> Technical + **tunable-parameter** reference for the Decks screen, the Collection (inventory), and the
> Card Creation Engine (per-card art assembly). Written so a human or an external model can understand
> the system AND find/change any knob in one lookup (see **§11 TUNABLE PARAMETERS**).
> Source of truth (verify against these — values below are current as of the Collection redesign):
> `scripts/ui/decks.gd`, `scripts/ui/match_card_ui.gd`, `scripts/ui/{rarity_icon,type_glyph_icon,placeholder_border}.gd`,
> `core/player_profile.gd`, `scripts/cards/card_catalog.gd`, `resources/card_resource.gd`, `scenes/{decks,match_card_ui}.tscn`.
> Engine: Godot 4.6.3 · portrait mobile-first (1080×1920) · `canvas_items` stretch.

---

## 0. Coordinate space (read first)

Everything is authored in a fixed **1080 × 1920 design canvas** (`const SCREEN`). `canvas_items` stretch
scales that whole canvas to the window (≈558×992 desktop, device-native on mobile). **Every pixel number
here is design-canvas units, not physical pixels.** Convert: `physical = design × (window_height / 1920)`.

---

## 1. Architecture

- **One scene, one script.** `scenes/decks.tscn` = a full-rect `Control` with `scripts/ui/decks.gd`.
  **100% built procedurally in code** — no authored node tree. Everything is `.new()`'d + absolutely placed.
- **Pure META.** All edits route through the `PlayerProfile` autoload → `user://profile.cfg`. The sim only
  reads `deck[type][0]` at offline match-start (headless-gated), so nothing here affects determinism.
- **Theme:** `res://ui/main_theme.tres` (Y2K) + `Y2KButton`. `msaa_2d=1` smooths the custom `_draw` edges.
- **Reusable helper Control classes** (`scripts/ui/`, global `class_name`, used by both `decks.gd`'s inner
  classes and `match_card_ui.tscn`): `RarityIcon`, `TypeGlyphIcon`, `PlaceholderBorder`.

### Layering (root `Control` children, back→front)
background (ColorRect) · `_landing` · `_builder` · `_deck_box` (tweens between states) · `_overlay` (modals).

---

## 2. Two states + transition

| State | Trigger | Contents |
|---|---|---|
| **MY DECKS** (landing) | initial | deck boxes (1 active + 2 LOCKED), editable deck name, Back |
| **BUILDER** | tap the active box | 4-band split: deck list / separator / **Collection** / dock |

`_apply_state(builder, animate)` tweens the shared `_deck_box` (position + scale) while the layers cross-fade
(0.42 s, `TRANS_CUBIC`). Landing box centre `(540,712)` scale `1.0`; builder dock centre `(540,1730)` scale `0.62`.

---

## 3. Builder layout bands

Constants at the top of `decks.gd`:

| Band | Const(s) | Y top | Height | Purpose |
|---|---|---|---|---|
| Deck list | `DECK_TOP` / `DECK_H` | 24 | 744 | 3 type rows × 5 pill slots; whole panel = drop target |
| Separator | `SEP_TOP` / `SEP_H` | 768 | 96 | "DECK n/15" + 3 **clickable** colored type counters |
| Collection | `INV_TOP` / `INV_H` | 864 | 768 | `COLLECTION_H` header (title + FILTERS) + scroll grid |
| Bottom dock | `BOTTOM_TOP` / `BOTTOM_H` | 1540 | 380 | docked deck box, slot arrows, deck name, Back |

---

## 4. Card variants & dimensions

Five render paths, all produced by `_make_tile()` / `_open_inspect()` / `match_card_ui.tscn`:

| Variant | Where | Size (W×H) | Derivation | Builder |
|---|---|---|---|---|
| **Deck pill** | deck list slots | **195.2 × 150** | `(SCREEN.x−56−12×4)/5`, fixed 150 | `CardTile._build_pill` |
| **Collection full card** | the grid | **334.67 × 340** | `(SCREEN.x−2·INV_MARGIN−2·18)/3` × `INV_CARD_H` | `CardTile._build_full` |
| **Big inspect** | tap-to-view | **864 × 1228.8** | `SCREEN.x·0.80` × `SCREEN.y·0.64` | `_open_inspect` |
| **In-round** | gameplay | **500 × 700** (5:7) | `MatchCardUI.REF_SIZE` | `match_card_ui.tscn` |
| Drag preview / Quantity / Filter popup | overlays | 220×84 / 780×560 / 880×660 | literals | `make_drag_preview` / `_open_quantity` / `_open_filter_popup` |

### 4a. Deck pill (`CardTile`, `full=false`)
Horizontal: art well left ~30% (`Rect2(12,10, size.x·0.30−8, size.y−20)`), **name only** (vertically
centred, no shorthand stats) right ~70%, frame over the **whole tile** (type-tinted), **rarity top-right**,
owned badge bottom-right. Compact text (`size.x<230`): name font 18 else 25. Slot-0 of each type = the
"loaded" card → gold border in `_draw_pill`.

### 4b. Collection full card (`CardTile`, `full=true`)
Vertical: **art on top** (`pad..size.y·0.50`, cover-cropped + clipped), **name** + **shorthand stats** below,
frame over the whole card, **rarity top-right**, owned badge bottom-right. `pad=12`, name font 24, stat 18,
rarity 40. 3 columns; `INV_CARD_H` (340) sets the height. *The 5 elements: border, name, art, rarity, stats.*

### 4c. Big inspect (`_open_inspect`)
MTG frame (gold border, `clip_contents`). Margin `m=22`. Header strip (type color) → art **well** (`H·0.40`,
type-tinted frame) → panel A (TYPE • DMG / rarity · faction) → panel B (rules + full stats, `AUTOWRAP_WORD`
+ ellipsis; auto-fills down to the buttons, so the bigger art tightens it) → action buttons (88 tall). A
**rarity icon** sits middle-right on panel A. Pop-in scale 0.72→1.0.

### 4d. In-round (`match_card_ui.tscn` + `MatchCardUI`)
STRICT **5:7**. Art (cover) under `border_in_round`, NAME on the top plate, **rarity bottom-center**. **No
rules text, ever.** `setup(card)` or the `card` export fills it.

---

## 5. Card Creation Engine (per-card art assembly)

Each card is assembled from at most: one **raw illustration** (`CardResource.card_art`) + one of three
**universal frame PNGs** + procedural **rarity** + the card's **text**. All asset loads are guarded, so the
game is never broken mid-art-pass.

- **Per-card art:** `@export var card_art: Texture2D` on `CardResource` (the "Card Art" group). Cover-cropped
  + clipped to each variant's art well/area.
- **Universal frames** (drop-in PNGs at `res://resources/cards/frames/`, exact names): `border_pill.png`
  (whole deck/Collection tile), `border_in_round.png` (whole 5:7 card), `border_full.png` (inspect art well).
- **Assembly order everywhere:** WELL(clip) → art(COVER) → frame → text/icons.
- **Robust fallbacks** (Phase 2):
  - No `card_art` → procedural **TypeGlyphIcon** (lightning/shield/frost).
  - No frame PNG → procedural **PlaceholderBorder** (cyan pill / gold in-round + inspect).
  - **RarityIcon** is always procedural until a real asset replaces it.
- **Helper classes:** `RarityIcon` (circle/diamond/star by rarity), `TypeGlyphIcon` (glyph by `card_type`;
  `static draw_glyph()` shared with the deck pill `_draw`), `PlaceholderBorder` (cyan/gold double-rect, `plate`
  adds a name band). Authoring SOP: `resources/cards/card_instructions.txt`.

---

## 6. Data model & rules

### 6a. `CardCatalog` (static registry — `scripts/cards/card_catalog.gd`)
`ENTRIES` = ordered `{id, path, type, rarity}` list (load-by-path, export-safe). 7 cards today. Adding a card
= one entry + its `.tres`. `type`: 0 ATK / 1 DEF / 2 CTR. `rarity`: 0 Common / 1 Uncommon / 2 Rare.

### 6b. `PlayerProfile` (state + rules — `core/player_profile.gd`)
- `deck = { "attack":[ids], "defense":[ids], "counter":[ids] }`. Legal = **5/5/5 = 15** (`PER_TYPE=5`).
- Copy limits by rarity: `COPY_LIMIT = {Common:5, Uncommon:2, Rare:1}`.
- Dev ownership: `DEV_GRANT_ALL=true`, `DEV_OWNED = {C:6, U:3, R:2}`.
- Dynamic add cap: `max_addable(id) = max(0, min(PER_TYPE−type_count, copy_limit−have, owned−have))`.
- Only `deck[type][0]` is loaded into an offline match (the gold-bordered "active" card).

---

## 7. Collection filters

- **FILTERS button** (Collection header) → `_open_filter_popup()`: a modal panel (880×660) with **search** +
  **type chips** (ALL/ATK/DEF/CTR) + **rarity chips** (ALL/C/U/R) + **CLEAR** / **DONE**. Live-updates the grid.
- **Separator type counters are clickable filters** (`_set_type_filter`): tap a colored counter to filter that
  type, tap the active one again to clear. Non-selected counters dim while a filter is active.
- Filter state: `_filter_type` (−1=all), `_filter_rarity` (−1=all), `_search`. Applied in `_rebuild_inventory`.

---

## 8. Interactions

| Gesture | Collection card | Deck pill |
|---|---|---|
| single tap | Big Inspect | Big Inspect (REMOVE/LOAD) |
| double tap | Quantity prompt | remove one |
| tap owned badge | Quantity prompt | — |
| drag → deck-list panel | add +1 | — |
| drag → filled same-type slot | replace | — |

Drag focus-pull dims non-matching types (0.18 s). Rejections: haptic + reason toast + counter shake + tile
flash. Deck rename: name button → `LineEdit` (≤18 chars). Haptics via `Input.vibrate_handheld` (no-op desktop).

---

## 9. Colors

- **Cards colored by TYPE** (`TYPE_COL`): 0 red / 1 green / 2 blue (faction is text-only).
- **Rarity** (`RARITY_COL`, used by stripe + `RarityIcon`): Common silver `(0.72,0.77,0.85)`, Uncommon green
  `(0.48,0.86,0.62)`, Rare gold `(1.0,0.81,0.36)`.
- Active deck-slot marker: gold border `(1.0,0.84,0.3)`.

---

## 10. Inner classes (decks.gd)
`CardTile` (pill + full via `full` flag; shared drag/tap logic), `DropZone`, `EmptySlot`, `SepBar`, `TypeDot`,
`DeckBoxIcon`, `PlayerProfileConst` (PER_TYPE shim). Inner classes are fed values by `_make_tile` (they can't
read outer consts) but CAN use the global `class_name` helpers.

---

## 11. ⭐ TUNABLE PARAMETERS (change-me reference)

### 11a. Layout bands — `scripts/ui/decks.gd` (top consts)
| Const | Value | Effect |
|---|---|---|
| `SCREEN` | (1080,1920) | the design canvas (don't change unless re-targeting) |
| `DECK_TOP` / `DECK_H` | 24 / 744 | deck-list band top / height |
| `SEP_TOP` / `SEP_H` | 768 / 96 | separator bar (counts + clickable type filters) |
| `INV_TOP` / `INV_H` | 864 / 768 | Collection band top / height |
| `COLLECTION_H` | 76 | Collection header height (title + FILTERS); rest of the band = grid |
| `INV_MARGIN` | 20 | symmetric L/R margin of the Collection grid |
| `SCROLLBAR_W` | 18 | scrollbar reserve (kept in the right margin → cards stay centred) |
| `INV_CARD_H` | 340 | **Collection full-card height** |
| `BOTTOM_TOP` / `BOTTOM_H` | 1540 / 380 | bottom dock |
| `DOUBLE_MS` | 260 | tap-vs-double-tap window |

### 11b. Card sizes / grid
| Knob | Where | Effect |
|---|---|---|
| deck pill height | `_rebuild_deck_list` → `Vector2(slot_w, 150)` | pill slot height |
| deck pill width | `_rebuild_deck_list` → `slot_w` formula | 5-across slot width |
| Collection columns | `_build_inventory_region` → `_inv_grid.columns = 3` | cards per row |
| Collection card W/H | `_rebuild_inventory` → `Vector2(col_w, INV_CARD_H)` | full-card size (W auto from columns) |
| grid gaps | `_inv_grid` `h_/v_separation = 18` | spacing between cards |
| Collection touch feel | `CardTile` `HOLD_MS` (150) · `MOVE_THRESH` (14) · `decks.gd` `SCROLL_FRICTION` (4) · `SCROLL_MIN_VEL` (8) | hold-then-move = pick up + drag; quick swipe = scroll; release = **flick momentum** (friction-decayed glide; tap-to-stop) |
| inspect size | `_open_inspect` → `face_sz = (SCREEN.x·0.80, SCREEN.y·0.64)` | Big inspect card |
| inspect art well | `_open_inspect` → `art_h = H·0.40` | bigger art → tighter Panel B (auto-fills to buttons) |
| in-round size | `match_card_ui.gd` → `REF_SIZE = (500,700)` | 5:7 card (keep 5:7!) |
| quantity / filter / drag-preview | `_open_quantity` 780×560 / `_open_filter_popup` 880×660 / `make_drag_preview` 220×84 | overlay sizes |

### 11c. Fonts / icon sizes — `CardTile`
| Knob | Where | Value |
|---|---|---|
| pill name / stat font | `_build_pill` | 18/25 (compact/full) · 14/19 |
| pill rarity icon | `_build_pill` → `rsz` | 28/32, top-right |
| full name / stat font | `_build_full` | 24 · 18 |
| full rarity icon | `_build_full` → `rar.size` | 40, top-right |
| owned badge | `_add_badge` | 58×38 |

### 11d. Game rules — `core/player_profile.gd`
| Const | Value | Effect |
|---|---|---|
| `PER_TYPE` | 5 | cards per type (deck = 3×) |
| `COPY_LIMIT` | {0:5, 1:2, 2:1} | max copies by rarity (Common/Uncommon/Rare) |
| `DEV_GRANT_ALL` | true | treat all cards as owned (flip when economy lands) |
| `DEV_OWNED` | {0:6, 1:3, 2:2} | dev-granted owned counts by rarity |
| deck-name cap | `set_deck_name` | 18 chars |

### 11e. Colors / frames
| Knob | Where | Effect |
|---|---|---|
| type colors | `decks.gd` `TYPE_COL` (+ `RarityIcon`/`card_hand_hud` mirror) | attack/defense/counter tints |
| rarity colors | `decks.gd` `RARITY_COL` & `rarity_icon.gd` `COL` | stripe + rarity shape tints |
| frame PNG paths | `decks.gd` `BORDER_PILL`/`BORDER_FULL`, `match_card_ui.gd` `BORDER_PATH` | where to drop real frames |
| border tint (by type) | frames set `modulate = TYPE_COL[type]` in `_build_pill`/`_build_full`/`_open_inspect` + `match_card_ui.gd` | red/green/blue border per Card Type (tints the grayscale PNG / placeholder) |
| placeholder base color | `placeholder_border.gd` `col` (near-white grayscale) | the un-tinted frame base that `modulate` multiplies |

### 11f. Per-card params — `resources/cards/<card>.tres` (`CardResource`)
`card_art` (raw illustration) + Identity (type/faction/rarity/cost) + the per-type gameplay block. See
`resources/cards/card_instructions.txt` (authoring SOP) and `Wizard_Dodgeball_Brain/CARD_FRAMEWORK.md`
(which gameplay params are free vs need code).

---

## 12. File map
| Concern | File |
|---|---|
| Deck builder + Collection UI (all of it) | `scripts/ui/decks.gd` |
| In-round card | `scripts/ui/match_card_ui.gd` + `scenes/match_card_ui.tscn` |
| Art-assembly helpers | `scripts/ui/{rarity_icon,type_glyph_icon,placeholder_border}.gd` |
| Profile + deck rules | `core/player_profile.gd` (`user://profile.cfg`) |
| Card registry | `scripts/cards/card_catalog.gd` |
| Per-card data | `resources/cards/*.tres` (`CardResource`) + `resources/cards/frames/*.png` |
| Authoring SOP | `resources/cards/card_instructions.txt` |
| Theme / buttons | `res://ui/main_theme.tres`, `scripts/ui/y2k_ui_button.gd` |
