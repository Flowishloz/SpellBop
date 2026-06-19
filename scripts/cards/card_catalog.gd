## card_catalog.gd — the export-safe registry of all spell CARDS (the card-pool content list).
##
## WHY THIS EXISTS: mirrors SkinCatalog — listing resources/cards/*.tres via DirAccess is unreliable in
## EXPORTED mobile builds, so the catalog is a COMMITTED, ordered list loaded BY PATH (load("res://…")
## is reliable in exports). The Decks builder + PlayerProfile both enumerate / resolve cards from here.
##
## DETERMINISM (Content Engine §1 two-layer rule): a card .tres is shared IMMUTABLE sim data, but THIS
## registry (ids / paths / metadata) is read ONLY in menus + at match-start setup, never inside a sim
## tick. The DEFAULT_* ids MUST match scenes/player.tscn's CardCasterComponent slots so a fresh profile
## reproduces today's hardcoded hand exactly (the headless determinism sweep stays bit-identical).
class_name CardCatalog
extends Object

## type mirrors CardResource.CardType (ATTACK=0, DEFENSE=1, COUNTER=2);
## rarity mirrors CardResource.Rarity (COMMON=0, UNCOMMON=1, RARE=2). Kept as plain ints so this
## registry never has to reference the CardResource enum at compile time.
const ENTRIES: Array = [
	# The 3 BASELINE cards (the default loadout — must match player.tscn).
	{"id": &"spark_bolt",   "path": "res://resources/cards/basic_attack.tres",  "type": 0, "rarity": 0},
	{"id": &"gaeas_wall",   "path": "res://resources/cards/basic_defense.tres", "type": 1, "rarity": 0},
	{"id": &"icey_retort",  "path": "res://resources/cards/basic_counter.tres", "type": 2, "rarity": 0},
	# WAVE 1 — param-only ATTACK commons (Content Engine P2). Reflectable (no shield-shatter), 1 DMG.
	{"id": &"slow_boulder", "path": "res://resources/cards/slow_boulder.tres", "type": 0, "rarity": 0},
	{"id": &"swift_dart",   "path": "res://resources/cards/swift_dart.tres",   "type": 0, "rarity": 0},
	# WAVE 2 — the DEFENSE BUFF archetype (Content Engine): timed self-buffs, deploy no wall.
	{"id": &"hermes_boon",  "path": "res://resources/cards/hermes_boon.tres",  "type": 1, "rarity": 0},
	{"id": &"focus_sigil",  "path": "res://resources/cards/focus_sigil.tres",  "type": 1, "rarity": 0},
]

## DEFAULT loadout (one card per type) — MUST equal scenes/player.tscn's CardCasterComponent slots, so a
## fresh / default profile reproduces today's hardcoded hand and the determinism sweep stays bit-identical.
const DEFAULT_ATTACK := &"spark_bolt"
const DEFAULT_DEFENSE := &"gaeas_wall"
const DEFAULT_COUNTER := &"icey_retort"


## The metadata entry {id, path, type, rarity} for a card id (empty dict if unknown).
static func entry_for(id: StringName) -> Dictionary:
	for e in ENTRIES:
		if e["id"] == id:
			return e
	return {}


## The CardResource for an id (null if unknown / load fails). Load-by-path (export-safe).
static func card_for(id: StringName) -> CardResource:
	var e := entry_for(id)
	if e.is_empty():
		return null
	return load(e["path"]) as CardResource


## All card ids of a CardType (0/1/2), in catalog order.
static func ids_of_type(card_type: int) -> Array:
	var out: Array = []
	for e in ENTRIES:
		if int(e["type"]) == card_type:
			out.append(e["id"])
	return out


## All card ids (catalog order).
static func all_ids() -> Array:
	var out: Array = []
	for e in ENTRIES:
		out.append(e["id"])
	return out


## The default (baseline) card id for a CardType — the one player.tscn hardcodes.
static func default_id(card_type: int) -> StringName:
	match card_type:
		1: return DEFAULT_DEFENSE
		2: return DEFAULT_COUNTER
		_: return DEFAULT_ATTACK


static func size() -> int:
	return ENTRIES.size()
