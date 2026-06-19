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
## type (15-card deck); the BASIC Decks menu this pass edits the ACTIVE (first) card of each type, and the
## OFFLINE match loads deck[type][0] into the caster's slot. Keys: "attack" / "defense" / "counter".
## Populated in _ready (NOT a member initializer) so the CardCatalog class is fully compiled first.
var deck: Dictionary = {}


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
# Persistence
# =====================================================================
## Drop any saved active card that no longer exists in the catalog back to the baseline (a deck is always
## legal — never empty, never a stale id).
func _ensure_legal() -> void:
	for t in 3:
		var key := type_key(t)
		var list: Array = deck.get(key, [])
		if list.is_empty() or CardCatalog.entry_for(StringName(list[0])).is_empty():
			deck[key] = [CardCatalog.default_id(t)]


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_PROFILE_PATH) != OK:
		return  # no profile yet — the baseline defaults stand (== today's hardcoded loadout)
	xp = int(cfg.get_value("progression", "xp", xp))
	level = int(cfg.get_value("progression", "level", level))
	coins = int(cfg.get_value("wallet", "coins", coins))
	gems = int(cfg.get_value("wallet", "gems", gems))
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
