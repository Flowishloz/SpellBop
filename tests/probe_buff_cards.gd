## probe_buff_cards.gd — regression probe for the Defense BUFF archetype: Hermes' Boon (move-speed boost,
## MovementComponent) + Focus Sigil (fireball haste, SpellCasterComponent). For EACH buff it verifies it is
## FUNCTIONAL, survives _save_state/_load_state, and is ROLLBACK bit-identical (save->ticks->load->replay).
##   godot --headless --path . -s res://tests/probe_buff_cards.gd
extends SceneTree

const MV := preload("res://scripts/player/components/movement_component.gd")
const SC := preload("res://scripts/player/components/spell_caster_component.gd")
const SR := preload("res://resources/spell_resource.gd")
var _fail: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var boosted: Array = _mk_mover()
	var baseline: Array = _mk_mover()
	var c: Array = _mk_mover()
	var d: Array = _mk_mover()
	var hasted: Array = _mk_caster()
	var normal: Array = _mk_caster()
	var hc: Array = _mk_caster()
	var hd: Array = _mk_caster()
	await process_frame  # _ready() caches fixed-point tuning + resolves _body on all

	# ===== MOVE-SPEED BOOST (Hermes' Boon) — MovementComponent =====
	boosted[1].apply_timed_boost(240, SGFixed.from_float(1.5))
	for i in 40:
		boosted[1]._network_process({&"x": 1})
		baseline[1]._network_process({&"x": 1})
	_check(boosted[0].fixed_position.x > baseline[0].fixed_position.x,
		"boost travels farther (%d > %d)" % [boosted[0].fixed_position.x, baseline[0].fixed_position.x])

	c[1].apply_timed_boost(240, SGFixed.from_float(1.5))
	for i in 20:
		c[1]._network_process({&"x": 1})
	var bsnap: Dictionary = c[1]._save_state()
	_check(int(bsnap.get("bt", 0)) > 0 and int(bsnap.get("bs", 0)) > SGFixed.ONE, "boost saved (bt/bs)")
	for i in 30:
		c[1]._network_process({&"x": 1})
	var blive: Dictionary = c[1]._save_state()
	d[1]._load_state(bsnap)
	for i in 30:
		d[1]._network_process({&"x": 1})
	_check(str(blive) == str(d[1]._save_state()), "boost rollback bit-identical")

	# ===== FIREBALL HASTE (Focus Sigil) — SpellCasterComponent =====
	# Hold the cast (charges toward the throwable mark; never released, so no projectile is spawned).
	hasted[1].apply_timed_haste(600, SGFixed.from_float(0.5))  # -50% charge + cooldown
	for i in 20:
		hasted[1]._network_process({&"c": 1})
		normal[1]._network_process({&"c": 1})
	_check(hasted[1]._charge_ticks > normal[1]._charge_ticks,
		"haste charges faster (%d > %d)" % [hasted[1]._charge_ticks, normal[1]._charge_ticks])

	hc[1].apply_timed_haste(600, SGFixed.from_float(0.5))
	for i in 10:
		hc[1]._network_process({&"c": 1})
	var hsnap: Dictionary = hc[1]._save_state()
	_check(int(hsnap.get("ht", 0)) > 0 and int(hsnap.get("hs", SGFixed.ONE)) < SGFixed.ONE, "haste saved (ht/hs)")
	for i in 20:
		hc[1]._network_process({&"c": 1})
	var hlive: Dictionary = hc[1]._save_state()
	hd[1]._load_state(hsnap)
	for i in 20:
		hd[1]._network_process({&"c": 1})
	_check(str(hlive) == str(hd[1]._save_state()), "haste rollback bit-identical")

	print("PROBE BUFF: %s (%d failures)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)


func _mk_mover() -> Array:
	var body := SGCharacterBody2D.new()
	var mover: Node = MV.new()
	body.add_child(mover)
	root.add_child(body)
	return [body, mover]


func _mk_caster() -> Array:
	var body := SGCharacterBody2D.new()
	var caster: Node = SC.new()
	var sp: Resource = SR.new()
	sp.set("cast_time", 0.5)   # gives a real charge window so the haste has something to speed up
	sp.set("base_speed", 800.0)
	caster.set("spell", sp)
	body.add_child(caster)
	root.add_child(body)
	return [body, caster]


func _check(cond: bool, label: String) -> void:
	print("  [%s] %s" % ["ok" if cond else "FAIL", label])
	if not cond:
		_fail += 1
