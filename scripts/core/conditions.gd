class_name Conditions
extends RefCounted

## Evaluates the condition strings used by card scripts.
## Add new conditions here; keep them side-effect free.


static func check(condition: String, state: MTGGameState, source: CardInstance, controller: int) -> bool:
	if condition.is_empty() or condition == "always":
		return true

	match condition:
		"not_your_turn":
			return state.active_player != controller

		"more_than_two_other_lands":
			var others := 0
			for card in state.players[controller].battlefield:
				if card.is_land() and (source == null or card.instance_id != source.instance_id):
					others += 1
			return others > 2

		"controls_island_or_mountain":
			for card in state.players[controller].battlefield:
				if card.has_subtype("Island") or card.has_subtype("Mountain"):
					return true
			return false

		"source_is_creature":
			return source != null and source.is_creature()

		"instant_and_sorcery_in_graveyard":
			var has_instant := false
			var has_sorcery := false
			for card in state.players[controller].graveyard:
				if card.definition == null:
					continue
				if card.definition.card_type == CardDefinition.CardType.INSTANT:
					has_instant = true
				elif card.definition.card_type == CardDefinition.CardType.SORCERY:
					has_sorcery = true
			return has_instant and has_sorcery

	# class_level==N / class_level>=N
	if condition.begins_with("class_level"):
		if source == null:
			return false
		if "==" in condition:
			return source.class_level == condition.get_slice("==", 1).to_int()
		if ">=" in condition:
			return source.class_level >= condition.get_slice(">=", 1).to_int()

	push_warning("Conditions: unknown condition '%s'" % condition)
	return false


## Number used by "cost_reduction" scripts.
static func count(what: String, state: MTGGameState, controller: int) -> int:
	match what:
		"instant_sorcery_in_graveyard":
			var n := 0
			for card in state.players[controller].graveyard:
				if card.definition and card.definition.is_instant_or_sorcery():
					n += 1
			return n
	push_warning("Conditions: unknown counter '%s'" % what)
	return 0


## Does a cast spell match a trigger filter?
static func spell_matches(filter: Dictionary, spell: CardInstance) -> bool:
	if spell == null or spell.definition == null:
		return false
	var def := spell.definition
	if filter.get("noncreature", false) and def.card_type == CardDefinition.CardType.CREATURE:
		return false
	if filter.get("instant_or_sorcery", false) and not def.is_instant_or_sorcery():
		return false
	if filter.has("color") and not def.is_color(filter["color"]):
		return false
	return true
