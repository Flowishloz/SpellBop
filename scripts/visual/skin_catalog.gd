## skin_catalog.gd — the export-safe registry of wizard skins (the wardrobe / shop content list).
##
## WHY THIS EXISTS: listing `assets_final/skins/*.tres` via DirAccess is unreliable in EXPORTED
## mobile builds (the SAME res:// dir-listing caveat the pose manifest works around). So the catalog
## is a COMMITTED, ordered list loaded BY PATH (`load("res://…")` is reliable in exports). The
## cosmetics carousel + locker + shop all enumerate from here.
##
## PRESENTATION ONLY — no sim / no saved state. Each entry's `owned` / `price` / `currency` are
## STATIC placeholder-economy data for the shop UI: this pass is visual-only, so nothing here is
## persisted, deducted, or equipped onto the match wizard yet (those are the flagged follow-ups).
## When real persistence lands (GameSettings / Nakama inventory RPCs), `owned` becomes a lookup and
## this stays the canonical id/price source.
class_name SkinCatalog
extends Object

## DEV MASTER-UNLOCK (development convenience). The shop BACKEND — real purchasing, earned coins, the
## Nakama inventory RPCs — does NOT exist yet, so while this is TRUE every skin reads as owned and is
## equippable: new sprites can be previewed on the podium AND equipped onto the title wizard with no
## paywall. The per-entry `owned` / `price` / `currency` data below is the (untouched) paywall
## FRAMEWORK — flip this to FALSE the day real ownership lands and the catalog gates exactly as
## designed, with no other code change. ALWAYS read ownership through is_owned(), never the raw field.
const DEV_UNLOCK_ALL := true

## Ordered skin list. `path` loads the SkinPalette; the rest is shop-placeholder metadata.
## currency: &"coins" (soft) / &"gems" (premium — the Chaos-Emerald currency) / &"" (free/owned).
const ENTRIES: Array = [
	{"id": &"default_blue", "path": "res://assets_final/skins/default_blue.tres", "owned": true,  "price": 0,   "currency": &""},
	{"id": &"default_red",  "path": "res://assets_final/skins/default_red.tres",  "owned": true,  "price": 0,   "currency": &""},
	{"id": &"neon",         "path": "res://assets_final/skins/neon.tres",         "owned": false, "price": 350, "currency": &"coins"},
	{"id": &"cyber_wizard", "path": "res://assets_final/skins/cyber_wizard.tres", "owned": false, "price": 500, "currency": &"gems"},
	{"id": &"space_wizard", "path": "res://assets_final/skins/space_wizard.tres", "owned": false, "price": 400, "currency": &"coins"},
]


## All SkinPalette resources, in catalog order (load-by-path; export-safe). Skips any that fail.
static func skins() -> Array:
	var out: Array = []
	for e in ENTRIES:
		var s: SkinPalette = load(e["path"]) as SkinPalette
		if s != null:
			out.append(s)
	return out


## The metadata entry {id, path, owned, price, currency} for a skin id (empty dict if unknown).
static func entry_for(id: StringName) -> Dictionary:
	for e in ENTRIES:
		if e["id"] == id:
			return e
	return {}


## Whether the player OWNS (can equip) a skin — the SINGLE ownership gate every screen must call.
## Honours the DEV_UNLOCK_ALL master switch first (dev: everything equippable); otherwise falls back
## to the entry's catalog `owned` flag (unknown ids default to owned, matching the prior UI default).
## When real purchasing lands, swap the fallback for the inventory lookup — call sites stay unchanged.
static func is_owned(id: StringName) -> bool:
	if DEV_UNLOCK_ALL:
		return true
	return bool(entry_for(id).get("owned", true))


## Catalog index of a skin id (-1 if absent) — lets the carousel sync to the podium's current skin.
static func index_of(id: StringName) -> int:
	for i in ENTRIES.size():
		if ENTRIES[i]["id"] == id:
			return i
	return -1


## The SkinPalette resource for a skin id (null if unknown / load fails). Lets any screen resolve a
## saved equipped-skin id back to its palette (e.g. the title-screen wizard).
static func palette_for(id: StringName) -> SkinPalette:
	var e := entry_for(id)
	if e.is_empty():
		return null
	return load(e["path"]) as SkinPalette


static func size() -> int:
	return ENTRIES.size()
