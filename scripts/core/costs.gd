class_name Costs
extends RefCounted

## Mana cost computation and payment planning.


## Total cost to cast a card right now (kicker and cost reductions included).
static func cast_cost(state: MTGGameState, card: CardInstance, controller: int, kicked: bool) -> Dictionary:
	var cost: Dictionary = card.definition.parsed_cost.duplicate()
	var rules := card.definition.rules

	if kicked and rules.has("kicker"):
		add(cost, CardDatabase.parse_mana_cost(rules["kicker"]))

	if rules.has("cost_reduction"):
		var reduction: Dictionary = rules["cost_reduction"]
		var amount: int = Conditions.count(reduction.get("per", ""), state, controller) * int(reduction.get("amount", 1))
		cost["generic"] = max(0, int(cost.get("generic", 0)) - amount)
	return cost


static func add(into: Dictionary, other: Dictionary) -> void:
	for key in other.keys():
		into[key] = into.get(key, 0) + other[key]


static func is_free(cost: Dictionary) -> bool:
	for key in cost.keys():
		if cost[key] > 0:
			return false
	return true


static func to_text(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	if cost.get("generic", 0) > 0:
		parts.append("{%d}" % cost["generic"])
	for color in MTGPlayer.COLORS:
		for i in range(int(cost.get(color, 0))):
			parts.append("{%s}" % color)
	return "".join(parts) if not parts.is_empty() else "{0}"


## Untapped permanents of `player_id` that can currently produce mana, with the
## colours each can make: Array of {"card": CardInstance, "colors": Array[String]}.
static func mana_sources(state: MTGGameState, player_id: int) -> Array:
	var sources: Array = []
	for card in state.players[player_id].battlefield:
		if card.tapped:
			continue
		var colors: Array = []
		for ability in card.mana_abilities():
			if Conditions.check(ability.get("condition", ""), state, card, player_id):
				colors.append(ability["color"])
		if not colors.is_empty():
			sources.append({"card": card, "colors": colors})
	return sources


## Plans which lands to tap (and for which colour) so that `cost` becomes payable
## on top of the player's current mana pool.
## Returns {"possible": bool, "actions": Array[MTGAction]}.
static func plan_land_taps(state: MTGGameState, player_id: int, cost: Dictionary) -> Dictionary:
	var player := state.players[player_id]
	var taps: Array[MTGAction] = []
	var pool: Dictionary = player.mana_pool.duplicate()
	var sources := mana_sources(state, player_id)

	# Colour requirements first, using the least flexible sources.
	sources.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["colors"].size() < b["colors"].size())

	for color in MTGPlayer.COLORS:
		var missing: int = int(cost.get(color, 0)) - int(pool.get(color, 0))
		while missing > 0:
			var idx := _find_source_with(sources, color)
			if idx == -1:
				return {"possible": false, "actions": taps}
			taps.append(_tap_action(player_id, sources[idx]["card"], color))
			sources.remove_at(idx)
			pool[color] = pool.get(color, 0) + 1
			missing -= 1

	var leftover := 0
	for color in MTGPlayer.COLORS:
		leftover += int(pool.get(color, 0)) - int(cost.get(color, 0))
	var generic_missing: int = int(cost.get("generic", 0)) - leftover
	while generic_missing > 0:
		if sources.is_empty():
			return {"possible": false, "actions": taps}
		var source: Dictionary = sources.pop_back()
		taps.append(_tap_action(player_id, source["card"], source["colors"][0]))
		generic_missing -= 1

	return {"possible": true, "actions": taps}


static func can_pay_with_taps(state: MTGGameState, player_id: int, cost: Dictionary) -> bool:
	return plan_land_taps(state, player_id, cost)["possible"]


static func _find_source_with(sources: Array, color: String) -> int:
	for i in range(sources.size()):
		if sources[i]["colors"].has(color):
			return i
	return -1


static func _tap_action(player_id: int, land: CardInstance, color: String) -> MTGAction:
	var act := MTGAction.new(MTGAction.ActionType.TAP_LAND, player_id)
	act.card_instance_id = land.instance_id
	act.mana_color = color
	return act
