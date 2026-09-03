class_name Triggers
extends RefCounted

## Turns game events into queued triggered abilities. The queue is drained by
## Effects.drain(); triggered abilities resolve immediately (they do not use the
## stack — a deliberate simplification that keeps the decision space small).
##
## Events:
##   "etb"        data: {"card": id}                       — a permanent entered the battlefield
##   "cast_spell" data: {"player": pid, "spell": id}       — a player cast a spell
##   "end_step"   data: {"player": pid}                    — beginning of that player's end step
##   "level_up"   data: {"card": id, "level": n}           — a Class gained a level


static func on_event(state: MTGGameState, event: String, data: Dictionary) -> void:
	match event:
		"etb":
			var card := state.find_card_instance(data["card"])
			if card:
				_queue_matching(state, card, event, data)

		"cast_spell":
			var caster: int = data["player"]
			var spell := state.find_card_instance(data["spell"])
			for card in state.players[caster].battlefield:
				_queue_matching(state, card, event, data)
				# Prowess is a keyword, not a script entry.
				if card.has_keyword("prowess") and spell and spell.definition \
						and spell.definition.card_type != CardDefinition.CardType.CREATURE:
					state.trigger_queue.append({
						"source": card.instance_id,
						"controller": card.controller_id,
						"trigger": {"effects": [{"type": "pump_self", "power": 1, "toughness": 1}]},
						"event_data": data,
					})

		"end_step":
			for card in state.players[data["player"]].battlefield:
				_queue_matching(state, card, event, data)

		"level_up":
			var card := state.find_card_instance(data["card"])
			if card:
				_queue_matching(state, card, event, data)


static func _queue_matching(state: MTGGameState, card: CardInstance, event: String, data: Dictionary) -> void:
	if card.definition == null:
		return
	for trigger in card.definition.rules.get("triggers", []):
		if trigger.get("event", "") != event:
			continue
		if not _filter_matches(state, trigger.get("filter", {}), event, data):
			continue
		if not Conditions.check(trigger.get("condition", ""), state, card, card.controller_id):
			continue
		state.trigger_queue.append({
			"source": card.instance_id,
			"controller": card.controller_id,
			"trigger": trigger,
			"event_data": data,
		})


static func _filter_matches(state: MTGGameState, filter: Dictionary, event: String, data: Dictionary) -> bool:
	match event:
		"cast_spell":
			return Conditions.spell_matches(filter, state.find_card_instance(data["spell"]))
		"level_up":
			return not filter.has("level") or int(filter["level"]) == int(data.get("level", -1))
	return true
