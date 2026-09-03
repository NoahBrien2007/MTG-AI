class_name Targeting
extends RefCounted

## Enumerates legal target assignments for a list of target specs.
##
## A spec is {"kind": String, "optional": bool, "max": int}. The result is an
## Array of assignments; each assignment is an Array of slots, where a slot is
## {"card": id, "spec": i} or {"player": pid, "spec": i}.
## "up to N" specs produce one assignment per subset of size 0..N.

const MAX_ASSIGNMENTS := 400


static func enumerate(state: MTGGameState, specs: Array, controller: int, source: CardInstance) -> Array:
	var per_spec: Array = []
	for i in range(specs.size()):
		var spec: Dictionary = specs[i]
		var candidates := candidates_for(state, spec, controller, source, i)
		var options: Array = []
		if spec.get("optional", false):
			options.append([])
		var max_count: int = spec.get("max", 1)
		for size in range(1, max_count + 1):
			options.append_array(_combinations(candidates, size))
		if options.is_empty():
			return [] # a required target with no legal choice: the spell can't be cast
		per_spec.append(options)

	var assignments: Array = [[]]
	for options in per_spec:
		var next: Array = []
		for prefix in assignments:
			for option in options:
				var combined: Array = []
				combined.append_array(prefix)
				combined.append_array(option)
				next.append(combined)
				if next.size() >= MAX_ASSIGNMENTS:
					break
			if next.size() >= MAX_ASSIGNMENTS:
				break
		assignments = next
	return assignments


## True if every card/player target still exists where the effect expects it.
static func is_slot_valid(state: MTGGameState, slot: Dictionary) -> bool:
	if slot.has("player"):
		return slot["player"] >= 0 and slot["player"] < state.players.size()
	return state.find_card_instance(slot.get("card", -1)) != null


static func candidates_for(state: MTGGameState, spec: Dictionary, controller: int, source: CardInstance, spec_index: int) -> Array:
	var slots: Array = []
	var kind: String = spec.get("kind", "any")
	var source_id := source.instance_id if source else -1

	match kind:
		"any":
			for card in _battlefield_creatures(state):
				if _targetable(card, controller):
					slots.append({"card": card.instance_id, "spec": spec_index})
			for p in state.players:
				slots.append({"player": p.player_id, "spec": spec_index})

		"creature":
			for card in _battlefield_creatures(state):
				if _targetable(card, controller):
					slots.append({"card": card.instance_id, "spec": spec_index})

		"creature_you_control":
			for card in state.players[controller].battlefield:
				if card.is_creature():
					slots.append({"card": card.instance_id, "spec": spec_index})

		"nonland_permanent":
			for p in state.players:
				for card in p.battlefield:
					if not card.is_land() and _targetable(card, controller):
						slots.append({"card": card.instance_id, "spec": spec_index})

		"spell_noncreature":
			for item in state.stack:
				var card: CardInstance = item["card"]
				if card.instance_id != source_id and card.definition and not card.definition.is_creature():
					slots.append({"card": card.instance_id, "spec": spec_index})

		"graveyard_instant_sorcery_yours":
			for card in state.players[controller].graveyard:
				if card.definition and card.definition.is_instant_or_sorcery():
					slots.append({"card": card.instance_id, "spec": spec_index})

		"player":
			for p in state.players:
				slots.append({"player": p.player_id, "spec": spec_index})

		_:
			push_warning("Targeting: unknown target kind '%s'" % kind)

	return slots


static func _battlefield_creatures(state: MTGGameState) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	for p in state.players:
		for card in p.battlefield:
			if card.is_creature():
				result.append(card)
	return result


## Hexproof: can't be targeted by opponents.
static func _targetable(card: CardInstance, by_player: int) -> bool:
	return card.controller_id == by_player or not card.has_keyword("hexproof")


static func _combinations(items: Array, size: int) -> Array:
	var result: Array = []
	if size > items.size():
		return result
	_combine(items, size, 0, [], result)
	return result


static func _combine(items: Array, size: int, start: int, current: Array, out: Array) -> void:
	if current.size() == size:
		out.append(current.duplicate())
		return
	for i in range(start, items.size()):
		current.append(items[i])
		_combine(items, size, i + 1, current, out)
		current.pop_back()
