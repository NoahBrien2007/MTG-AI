class_name OracleParser
extends RefCounted

## Best-effort fallback that turns simple templated oracle text into a rules
## script for cards that have no hand-written entry in CardLibrary. It only
## recognises a handful of common patterns; anything more exotic needs a
## library entry. Recognised text is listed in `derive()`.

const NUMBER_WORDS := {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5}


static func derive(def: CardDefinition, produced_mana: String) -> Dictionary:
	var script: Dictionary = {}
	var text := def.oracle_text.to_lower()

	# Lands: one mana ability per produced colour.
	if def.card_type == CardDefinition.CardType.LAND:
		var mana: Array = []
		for color in MTGPlayer.COLORS:
			if color in produced_mana:
				mana.append({"color": color})
		if mana.is_empty():
			mana = _infer_land_mana(def)
		script["mana"] = mana
		if "enters tapped" in text and "unless" not in text and "pay" not in text:
			script["enters_tapped"] = "always"
		return script

	if def.card_type != CardDefinition.CardType.INSTANT and def.card_type != CardDefinition.CardType.SORCERY:
		return script

	var targets: Array = []
	var effects: Array = []

	# "deals N damage to any target" / "to target creature" / "to target player or planeswalker"
	var dmg := RegEx.create_from_string("deals (\\d+) damage to (any target|target creature|target player|target opponent|each opponent)").search(text)
	if dmg:
		var amount := dmg.get_string(1).to_int()
		match dmg.get_string(2):
			"any target":
				targets.append({"kind": "any"})
				effects.append({"type": "damage", "amount": amount, "target": targets.size() - 1})
			"target creature":
				targets.append({"kind": "creature"})
				effects.append({"type": "damage", "amount": amount, "target": targets.size() - 1})
			"target player", "target opponent":
				targets.append({"kind": "player"})
				effects.append({"type": "damage", "amount": amount, "target": targets.size() - 1})
			"each opponent":
				effects.append({"type": "damage_each_opponent", "amount": amount})

	# "target creature gets +N/+N until end of turn"
	var pump := RegEx.create_from_string("target creature (you control )?gets ([+-]\\d+)/([+-]\\d+)").search(text)
	if pump:
		targets.append({"kind": "creature_you_control" if not pump.get_string(1).is_empty() else "creature"})
		effects.append({"type": "pump", "target": targets.size() - 1,
			"power": pump.get_string(2).to_int(), "toughness": pump.get_string(3).to_int()})

	# "scry N"
	var scry := RegEx.create_from_string("scry (\\d+)").search(text)
	if scry:
		effects.append({"type": "scry", "count": scry.get_string(1).to_int()})

	# "draw a card" / "draw two cards"
	var draw := RegEx.create_from_string("draw (a|an|one|two|three|four|\\d+) cards?").search(text)
	if draw:
		var word := draw.get_string(1)
		var count: int = NUMBER_WORDS.get(word, word.to_int())
		effects.append({"type": "draw", "count": count})

	if not targets.is_empty():
		script["targets"] = targets
	if not effects.is_empty():
		script["spell"] = effects
	return script


static func _infer_land_mana(def: CardDefinition) -> Array:
	var mana: Array = []
	var text := (def.type_line + " " + def.oracle_text).to_lower()
	for basic in CardInstance.BASIC_TYPE_COLORS.keys():
		var color: String = CardInstance.BASIC_TYPE_COLORS[basic]
		if basic.to_lower() in text or ("{%s}" % color.to_lower()) in text:
			mana.append({"color": color})
	if mana.is_empty():
		mana.append({"color": "C"})
	return mana
