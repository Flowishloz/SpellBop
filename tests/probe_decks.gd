## probe_decks.gd — regression probe for the DECK BUILDER (Content Engine P4 overhaul).
## Verifies (a) PlayerProfile's copy-limit / owned / dynamic-cap math, (b) add/remove/make_active mutate
## the deck correctly, and (c) scenes/decks.tscn instantiates + builds headless with no script error
## (a compile + _ready smoke for decks.gd, which is otherwise only reached from the menu).
##
## SAFE: the user's real user://profile.cfg (their saved deck) is BACKED UP at start and RESTORED at the
## end — the mutating tests never leave the saved deck changed.
##   godot --headless --path . -s res://tests/probe_decks.gd
extends SceneTree

const PROFILE := "user://profile.cfg"
var _fail: int = 0
var _profile_backup: String = ""
var _profile_existed: bool = false


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_backup_profile()
	var pp: Node = root.get_node_or_null("PlayerProfile")
	_check(pp != null, "PlayerProfile autoload present")
	if pp == null:
		_finish()
		return

	# ===== A. READ-ONLY cap math (manipulate the in-memory deck, then restore it — never persisted) =====
	var original: Dictionary = (pp.deck as Dictionary).duplicate(true)
	pp.deck = {"attack": [], "defense": [], "counter": []}
	_check(pp.copy_limit(&"spark_bolt") == 5, "common copy-limit = 5")
	_check(pp.owned_count(&"spark_bolt") == 6, "dev-owned common = 6")
	_check(pp.max_addable(&"spark_bolt") == 5, "empty attack: max_addable = 5 (capped by rarity, not owned)")
	pp.deck = {"attack": [&"spark_bolt", &"spark_bolt", &"spark_bolt", &"spark_bolt", &"spark_bolt"],
		"defense": [], "counter": []}
	_check(pp.count_in_deck(&"spark_bolt") == 5, "5 copies counted in deck")
	_check(pp.type_count(0) == 5, "attack type at 5/5")
	_check(pp.max_addable(&"spark_bolt") == 0, "rarity cap hit: max_addable = 0")
	_check(pp.max_addable(&"slow_boulder") == 0, "type full: a fresh card also caps at 0")
	_check(pp.total_count() == 5 and not pp.is_deck_complete(), "total 5, deck not complete")
	pp.deck = original   # restore in-memory (no save)

	# ===== B. MUTATING add / remove / make_active (file backed up; restored in _finish) =====
	pp.use_default_deck()
	_check(pp.add_card(&"slow_boulder", 2) == 2, "add 2 slow_boulder -> 2 added")
	_check(pp.count_in_deck(&"slow_boulder") == 2 and pp.type_count(0) == 3, "attack now 3 (default + 2)")
	_check(pp.add_card(&"slow_boulder", 10) == 2, "add 10 more -> clamps to 2 (type space)")
	_check(pp.type_count(0) == 5 and pp.count_in_deck(&"slow_boulder") == 4, "attack full at 5, 4 boulders")
	_check(pp.add_card(&"swift_dart", 1) == 0, "attack full -> swift_dart rejected (0 added)")
	_check(pp.remove_card(&"slow_boulder"), "remove one boulder")
	_check(pp.count_in_deck(&"slow_boulder") == 3 and pp.type_count(0) == 4, "attack back to 4")
	_check(pp.add_card(&"swift_dart", 1) == 1, "now swift_dart fits")
	_check(pp.make_active(&"swift_dart"), "make_active swift_dart")
	_check(StringName((pp.deck_list(0))[0]) == &"swift_dart", "swift_dart promoted to slot 0 (loads in match)")
	# replace-on-drop (same-type only)
	_check(pp.replace_at(0, 1, &"swift_dart"), "replace deck slot 1 with swift_dart")
	_check(StringName((pp.deck_list(0))[1]) == &"swift_dart", "slot 1 is now swift_dart")
	_check(not pp.replace_at(0, 1, &"gaeas_wall"), "replace rejects a wrong-type card (defense into attack)")
	# deck naming
	pp.set_deck_name("Aggro Test")
	_check(pp.deck_name == "Aggro Test", "deck rename takes")
	pp.set_deck_name("")
	_check(pp.deck_name == "Deck 1", "empty rename falls back to Deck 1")
	pp.set_deck_name("ThisDeckNameIsFarTooLong")
	_check(pp.deck_name.length() <= 18, "long deck name capped to 18 chars (got %d)" % pp.deck_name.length())

	# ===== C. scenes/decks.tscn instantiates + builds (compile + _ready smoke) =====
	var packed: PackedScene = load("res://scenes/decks.tscn")
	_check(packed != null, "decks.tscn loads")
	if packed != null:
		var inst: Node = packed.instantiate()
		root.add_child(inst)
		await process_frame
		await process_frame
		_check(inst.get_child_count() > 0, "decks screen built children in _ready")
		_check(inst.get("_pp") != null, "decks screen resolved PlayerProfile")
		inst.free()

	_finish()


func _finish() -> void:
	_restore_profile()
	print("PROBE DECKS: %s (%d failures)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	if _fail != 0:
		printerr("PROBE DECKS FAILED (%d)" % _fail)   # STDERR too (the printerr-vs-stdout lesson)
	quit(_fail)


func _backup_profile() -> void:
	_profile_existed = FileAccess.file_exists(PROFILE)
	if _profile_existed:
		_profile_backup = FileAccess.get_file_as_string(PROFILE)


func _restore_profile() -> void:
	if _profile_existed:
		var f := FileAccess.open(PROFILE, FileAccess.WRITE)
		if f != null:
			f.store_string(_profile_backup)
			f.close()
	elif FileAccess.file_exists(PROFILE):
		var d := DirAccess.open("user://")
		if d != null:
			d.remove("profile.cfg")


func _check(cond: bool, label: String) -> void:
	print("  [%s] %s" % ["ok" if cond else "FAIL", label])
	if not cond:
		_fail += 1
