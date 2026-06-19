## player_profile.gd — the persistent PLAYER PROFILE (autoload: PlayerProfile).
##
## ROLE (Content Engine P0): the single source of truth for META progression + economy + the equipped
## deck. Mirrors GameSettings' proven pattern (load in _ready, each setter writes the ConfigFile + emits a
## changed signal, consumers read once + connect). PERSISTED to user://profile.cfg — a SEPARATE file from
## settings.cfg (economy/progression kept apart from presentation prefs).
##
## DETERMINISM (Content Engine §1 two-layer rule): this is META state. It is read ONLY outside a sim tick
## — menus + match-start setup (MatchController._apply_loadout, OFFLINE only). The SIM never reads it
## mid-tick. A fresh / default profile reproduces today's hardcoded loadout EXACTLY (CardCatalog defaults
## == player.tscn slots), so a clean determinism sweep stays bit-identical. The sweep DOES read the real
## user:// (the ai_difficulty lesson), so suites that build an offline match call use_default_deck().
extends Node

const _PROFILE_PATH := "user://profile.cfg"

## Fired when the equipped deck/loadout changes (the Decks menu → here). Consumers re-read.
signal deck_changed

# --- PROGRESSION + WALLET (stubs this pass; Content Engine P1 wires XP/levels, P5 wires currency/packs) ---
var xp: int = 0
var level: int = 1
var coins: int = 0
var gems: int = 0

# --- OWNED INVENTORY (stub this pass; P5 fills it from earned/pack rewards). While empty, the Decks
#     builder shows the FULL catalog pool (dev-grant), exactly like SkinCatalog.DEV_UNLOCK_ALL. ---
var owned_spells: Dictionary = {}

## THE EQUIPPED DECK — per type, an ORDERED list of card ids (CardCatalog ids). The full design is 5 per
## type (15-card deck); the builder edits the whole list, the OFFLINE match loads deck[type][0] (the
## ACTIVE / "loaded" card) into the caster's slot. Keys: "attack" / "defense" / "counter".
## Populated in _ready (NOT a member initializer) so the CardCatalog class is fully compiled first.
var deck: Dictionary = {}

## Player-facing deck name (the Decks landing screen, editable). Cosmetic only — never read by the sim.
var deck_name: String = "Deck 1"

# --- DECK-BUILD RULES (Content Engine §4) — enforced by the BUILDER UI, NEVER at runtime (the sim only
#     consumes deck[type][0] today, so these caps can't desync anything). ---
## Max copies of ONE card allowed in a deck, by rarity (COMMON=0 / UNCOMMON=1 / RARE=2). CD spec
## 2026-06-19: 5 / 2 / 1. SINGLE SOURCE OF TRUTH — the builder grid + the quantity prompt both read this.
const COPY_LIMIT := {0: 5, 1: 2, 2: 1}
## A legal deck holds exactly this many of EACH type (5 attack + 5 defense + 5 counter = 15 total).
const PER_TYPE := 5

## DEV inventory grant (mirrors SkinCatalog.DEV_UNLOCK_ALL): until packs/economy (P5) fill owned_spells,
## the builder treats every catalog card as OWNED. Counts EXCEED the copy-limit on purpose so the dynamic
## cap is testable (own 6 of a common, but the deck still caps at 5). Flip false when ownership is real.
const DEV_GRANT_ALL := true
const DEV_OWNED := {0: 6, 1: 3, 2: 2}   # rarity -> dev-granted owned count


func _ready() -> void:
	use_default_deck()  # baseline == player.tscn (a no-file profile reproduces today's hand)
	_load()
	_ensure_legal()


# =====================================================================
# Type-key helpers (CardResource.CardType 0/1/2 ↔ the deck dict keys)
# =====================================================================
static func type_key(card_type: int) -> String:
	match card_type:
		1: return "defense"
		2: return "counter"
		_: return "attack"


# =====================================================================
# DECK / loadout
# =====================================================================
## The ACTIVE card id for a CardType (the first deck entry; falls back to the catalog default).
func active_card_id(card_type: int) -> StringName:
	var list: Array = deck.get(type_key(card_type), [])
	if list.is_empty():
		return CardCatalog.default_id(card_type)
	return StringName(list[0])


## The ACTIVE CardResource for a CardType (null if it fails to resolve).
func active_card(card_type: int) -> CardResource:
	return CardCatalog.card_for(active_card_id(card_type))


## TRUE when the loadout is exactly the baseline (== player.tscn). MatchController._apply_loadout skips
## when true, so a fresh profile (and the determinism suites) leave the caster's scene cards untouched.
func is_default_deck() -> bool:
	return active_card_id(0) == CardCatalog.DEFAULT_ATTACK \
		and active_card_id(1) == CardCatalog.DEFAULT_DEFENSE \
		and active_card_id(2) == CardCatalog.DEFAULT_COUNTER


## Set the active card for a CardType (the Decks menu). Persists + emits. Ignores cards of the wrong type.
func set_active_card(card_type: int, id: StringName) -> void:
	var e := CardCatalog.entry_for(id)
	if e.is_empty() or int(e["type"]) != card_type:
		return
	deck[type_key(card_type)] = [id]
	_save()
	deck_changed.emit()


## Reset the loadout to the baseline (== player.tscn). Used by setup + by determinism suites to neutralize
## any persisted custom deck (hermeticity — the sweep reads the real user://profile.cfg).
func use_default_deck() -> void:
	deck = {
		"attack": [CardCatalog.DEFAULT_ATTACK],
		"defense": [CardCatalog.DEFAULT_DEFENSE],
		"counter": [CardCatalog.DEFAULT_COUNTER],
	}


# =====================================================================
# DECK BUILDER API (Content Engine P4 — the full 5/5/5 builder; META only, read outside sim ticks)
# =====================================================================
## Max copies of `id` allowed in a deck (by its rarity). 0 if the id is unknown.
func copy_limit(id: StringName) -> int:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return 0
	return int(COPY_LIMIT.get(int(e["rarity"]), 1))


## How many copies of `id` the player OWNS (dev-granted while DEV_GRANT_ALL; else the real inventory).
func owned_count(id: StringName) -> int:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return 0
	if DEV_GRANT_ALL:
		return int(DEV_OWNED.get(int(e["rarity"]), 1))
	return int(owned_spells.get(id, 0))


## The ordered list of card ids in the deck for a CardType (a LIVE reference — copy before mutating).
func deck_list(card_type: int) -> Array:
	return deck.get(type_key(card_type), [])


## Copies of `id` currently in the deck (searched within its own type list).
func count_in_deck(id: StringName) -> int:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return 0
	var n := 0
	for v in deck_list(int(e["type"])):
		if StringName(v) == id:
			n += 1
	return n


## Cards slotted in a type (0..PER_TYPE).
func type_count(card_type: int) -> int:
	return deck_list(card_type).size()


## Total cards across all three types (0..15).
func total_count() -> int:
	return type_count(0) + type_count(1) + type_count(2)


## TRUE when the deck is a legal 5/5/5 (15 cards).
func is_deck_complete() -> bool:
	return type_count(0) == PER_TYPE and type_count(1) == PER_TYPE and type_count(2) == PER_TYPE


## How many MORE copies of `id` may be added RIGHT NOW — clamped by (a) the rarity copy-limit, (b) how many
## the player owns, and (c) the free slots left in that type. Drives the quantity prompt's DYNAMIC cap
## (own 6 of a common but the deck already holds 5 of its type → 0; own 6, hold 2 → min(5-2, 6-2) = 3).
func max_addable(id: StringName) -> int:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return 0
	var already := count_in_deck(id)
	var by_rarity := copy_limit(id) - already
	var by_owned := owned_count(id) - already
	var by_type := PER_TYPE - type_count(int(e["type"]))
	return maxi(0, mini(by_type, mini(by_rarity, by_owned)))


## Add up to `n` copies of `id` to the deck, clamped by max_addable(). Returns the count ACTUALLY added
## (0 = fully rejected → the caller shakes / haptic-buzzes). Persists + emits deck_changed on success.
func add_card(id: StringName, n: int = 1) -> int:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return 0
	var add := mini(n, max_addable(id))
	if add <= 0:
		return 0
	var key := type_key(int(e["type"]))
	var list: Array = deck.get(key, [])
	for _i in add:
		list.append(id)
	deck[key] = list
	_save()
	deck_changed.emit()
	return add


## Remove ONE copy of `id` (its LAST occurrence) from the deck. Returns true if a copy was removed.
func remove_card(id: StringName) -> bool:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return false
	var key := type_key(int(e["type"]))
	var list: Array = deck.get(key, [])
	for i in range(list.size() - 1, -1, -1):
		if StringName(list[i]) == id:
			list.remove_at(i)
			deck[key] = list
			_save()
			deck_changed.emit()
			return true
	return false


## Remove the card at a specific (type, index) deck slot — the deck-tile remove. Returns true on success.
func remove_at(card_type: int, index: int) -> bool:
	var key := type_key(card_type)
	var list: Array = deck.get(key, [])
	if index < 0 or index >= list.size():
		return false
	list.remove_at(index)
	deck[key] = list
	_save()
	deck_changed.emit()
	return true


## Promote the first copy of `id` to slot 0 of its type — the card OFFLINE matches load + TEST (see
## MatchController._apply_loadout, which reads active_card = deck[type][0]). Returns true if it's now active.
func make_active(id: StringName) -> bool:
	var e := CardCatalog.entry_for(id)
	if e.is_empty():
		return false
	var key := type_key(int(e["type"]))
	var list: Array = deck.get(key, [])
	for i in list.size():
		if StringName(list[i]) == id:
			if i == 0:
				return true   # already active — no change
			list.remove_at(i)
			list.push_front(id)
			deck[key] = list
			_save()
			deck_changed.emit()
			return true
	return false


## Replace the card at (type, index) with `id` (drag-onto-a-filled-slot). Validates the new card is the
## right type and that the swap won't break its rarity / owned copy limit. Returns true on success.
func replace_at(card_type: int, index: int, id: StringName) -> bool:
	var e := CardCatalog.entry_for(id)
	if e.is_empty() or int(e["type"]) != card_type:
		return false
	var key := type_key(card_type)
	var list: Array = deck.get(key, [])
	if index < 0 or index >= list.size():
		return false
	if StringName(list[index]) == id:
		return true   # same card already there — no-op
	# Count existing copies of `id` OUTSIDE the slot being overwritten; the swap must stay legal.
	var others := 0
	for i in list.size():
		if i != index and StringName(list[i]) == id:
			others += 1
	if others >= copy_limit(id) or others >= owned_count(id):
		return false
	list[index] = id
	deck[key] = list
	_save()
	deck_changed.emit()
	return true


## Rename the active deck (the Decks landing screen). Trims, caps length, never empty. Persists + emits.
func set_deck_name(new_name: String) -> void:
	var trimmed := new_name.strip_edges()
	if trimmed.length() > 18:
		trimmed = trimmed.substr(0, 18)
	deck_name = trimmed if trimmed != "" else "Deck 1"
	_save()
	deck_changed.emit()


# =====================================================================
# Persistence
# =====================================================================
## Sanitize a loaded deck so it is always LEGAL: drop unknown / wrong-type ids, clamp each card to its
## rarity copy-limit, clamp each type to PER_TYPE. A type that empties out falls back to the baseline card,
## so active_card_id() stays valid and a fresh/default profile still reproduces player.tscn exactly (the
## headless determinism sweep stays bit-identical). Preserves a full multi-card deck (does NOT collapse it).
func _ensure_legal() -> void:
	for t in 3:
		var key := type_key(t)
		var raw: Array = deck.get(key, [])
		var clean: Array = []
		var per_id: Dictionary = {}
		for v in raw:
			var id := StringName(v)
			var e := CardCatalog.entry_for(id)
			if e.is_empty() or int(e["type"]) != t:
				continue   # drop unknown / wrong-type ids
			var used := int(per_id.get(id, 0))
			if used >= int(COPY_LIMIT.get(int(e["rarity"]), 1)):
				continue   # drop copies beyond this card's rarity cap
			if clean.size() >= PER_TYPE:
				break      # drop copies beyond 5 in this type
			per_id[id] = used + 1
			clean.append(id)
		if clean.is_empty():
			clean = [CardCatalog.default_id(t)]   # never empty (keeps active_card_id valid == today)
		deck[key] = clean


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_PROFILE_PATH) != OK:
		return  # no profile yet — the baseline defaults stand (== today's hardcoded loadout)
	xp = int(cfg.get_value("progression", "xp", xp))
	level = int(cfg.get_value("progression", "level", level))
	coins = int(cfg.get_value("wallet", "coins", coins))
	gems = int(cfg.get_value("wallet", "gems", gems))
	var inv: Variant = cfg.get_value("inventory", "spells", {})   # {} default: no "missing key" error when absent
	if inv is Dictionary and not (inv as Dictionary).is_empty():
		owned_spells = inv   # real ownership (DEV_GRANT_ALL still overrides reads until economy lands)
	deck_name = String(cfg.get_value("deck", "name", deck_name))
	for key in ["attack", "defense", "counter"]:
		var saved: Variant = cfg.get_value("deck", key, null)
		if saved is Array and not (saved as Array).is_empty():
			deck[key] = _as_string_names(saved)


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PROFILE_PATH)  # preserve any other sections
	cfg.set_value("progression", "xp", xp)
	cfg.set_value("progression", "level", level)
	cfg.set_value("wallet", "coins", coins)
	cfg.set_value("wallet", "gems", gems)
	cfg.set_value("inventory", "spells", owned_spells)
	cfg.set_value("deck", "name", deck_name)
	for key in ["attack", "defense", "counter"]:
		cfg.set_value("deck", key, _as_strings(deck.get(key, [])))
	cfg.save(_PROFILE_PATH)


# ConfigFile round-trips StringName arrays unreliably — store as String, reload as StringName.
func _as_strings(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(String(v))
	return out


func _as_string_names(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(StringName(v))
	return out
