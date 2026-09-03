class_name Effects
extends RefCounted

## Resolves effect lists from card scripts.
##
## An effect context (ctx) is a plain Dictionary so it survives state cloning:
##   {"source": card id, "controller": pid, "targets": Array of slots,
##    "kicked": bool, "effects": remaining effects, "on_complete": String}
##
## Effects that need a decision (scry, pick a card, pay or not, choose targets)
## store the context in state.pending_choice and return false; the game then
## offers CHOOSE actions to the deciding player and resume() continues.
##
## To add an effect: add a branch to _apply(). Nothing else needs to change.


# ───────────────────────────── Running ─────────────────────────────

static func make_context(source_id: int, controller: int, effects: Array, targets: Array = [], kicked: bool = false) -> Dictionary:
	return {
		"source": source_id,
		"controller": controller,
		"targets": targets.duplicate(true),
		"kicked": kicked,
		"effects": effects.duplicate(true),
		"on_complete": "",
	}


## Runs the remaining effects. Returns false if a choice is now pending.
static func run(state: MTGGameState, ctx: Dictionary) -> bool:
	while not ctx["effects"].is_empty():
		var effect: Dictionary = ctx["effects"].pop_front()
		if not _apply(state, ctx, effect):
			return false
	_complete(state, ctx)
	return true


## Answers the pending choice with option `choice_index` and continues.
static func resume(state: MTGGameState, choice_index: int) -> void:
	var pending: Dictionary = state.pending_choice
	state.pending_choice = {}
	if pending.is_empty() or choice_index < 0 or choice_index >= pending["options"].size():
		return
	var option: Dictionary = pending["options"][choice_index]
	var ctx: Dictionary = pending["ctx"]
	var data: Dictionary = pending.get("data", {})
	var continue_running := true

	match pending["kind"]:
		"scry":
			var card_id: int = data["cards"][data["index"]]
			if option.get("keep", true):
				data["kept"].append(card_id)
			else:
				data["bottom"].append(card_id)
			data["index"] += 1
			if data["index"] < data["cards"].size():
				_set_pending(state, ctx, "scry", ctx["controller"], _scry_options(state, data), data)
				continue_running = false
			else:
				_finish_scry(state, ctx["controller"], data)

		"pick_card":
			var player := state.players[ctx["controller"]]
			var card_id: int = option["card"]
			data["cards"].erase(card_id)
			var card := _take_from_list(player.library, card_id)
			if card:
				player.hand.append(card)
			data["take_left"] -= 1
			if data["take_left"] > 0 and not data["cards"].is_empty():
				_set_pending(state, ctx, "pick_card", ctx["controller"], _pick_options(state, data), data)
				continue_running = false
			else:
				# The cards that were looked at but not taken go to the bottom.
				for remaining_id in data["cards"]:
					var remaining := _take_from_list(player.library, remaining_id)
					if remaining:
						player.library.push_front(remaining)

		"pay_or_not":
			var payer: int = data["payer"]
			if option.get("pay", false):
				pay_cost(state, payer, data["cost"])
			else:
				counter_spell(state, data["spell"])

		"targets":
			ctx["targets"] = option["slots"]

	if continue_running:
		run(state, ctx)
	drain(state)


## Resolves queued triggered abilities until the queue is empty or a choice is pending.
static func drain(state: MTGGameState) -> void:
	while state.pending_choice.is_empty() and not state.trigger_queue.is_empty():
		var queued: Dictionary = state.trigger_queue.pop_front()
		_start_trigger(state, queued)


static func _start_trigger(state: MTGGameState, queued: Dictionary) -> void:
	var source := state.find_card_instance(queued["source"])
	if source == null:
		return
	var trigger: Dictionary = queued["trigger"]
	var ctx := make_context(source.instance_id, queued["controller"], trigger.get("effects", []))

	var specs: Array = trigger.get("targets", [])
	if not specs.is_empty():
		var assignments := Targeting.enumerate(state, specs, ctx["controller"], source)
		if assignments.is_empty():
			return # no legal targets: the ability does nothing
		if assignments.size() == 1:
			ctx["targets"] = assignments[0]
		else:
			var options: Array = []
			for slots in assignments:
				options.append({"label": describe_slots(state, slots, "nothing"), "slots": slots})
			_set_pending(state, ctx, "targets", ctx["controller"], options, {})
			return
	run(state, ctx)


# ───────────────────────────── Effects ─────────────────────────────

static func _apply(state: MTGGameState, ctx: Dictionary, effect: Dictionary) -> bool:
	var controller: int = ctx["controller"]
	var player := state.players[controller]
	var source := state.find_card_instance(ctx["source"])

	match effect["type"]:
		"damage":
			var amount: int = effect.get("amount", 0)
			if ctx["kicked"] and effect.has("kicked_amount"):
				amount = effect["kicked_amount"]
			for slot in _slots_for(ctx, effect):
				if slot.has("player"):
					state.players[slot["player"]].life -= amount
				else:
					var card := _battlefield_card(state, slot["card"])
					if card and card.is_creature():
						card.damage_marked += amount

		"damage_each_opponent":
			for p in state.players:
				if p.player_id != controller:
					p.life -= int(effect.get("amount", 0))

		"tap", "untap":
			for slot in _slots_for(ctx, effect):
				var card := _battlefield_card(state, slot.get("card", -1))
				if card:
					card.tapped = effect["type"] == "tap"

		"untap_self":
			if source:
				source.tapped = false

		"draw":
			for i in range(int(effect.get("count", 1))):
				player.draw_card()

		"scry":
			var count: int = min(int(effect.get("count", 1)), player.library.size())
			if count <= 0:
				return true
			var data := {"cards": _take_top_ids(player, count), "index": 0, "kept": [], "bottom": []}
			_set_pending(state, ctx, "scry", controller, _scry_options(state, data), data)
			return false

		"look_and_take":
			var look: int = min(int(effect.get("look", 1)), player.library.size())
			if look <= 0:
				return true
			var take: int = int(effect.get("take", 1))
			if effect.has("take_alt") and Conditions.check(effect.get("alt_condition", ""), state, source, controller):
				take = int(effect["take_alt"])
			# Cards stay in the library (so state cloning keeps working) and are
			# referenced by id until the player has picked.
			var data := {"cards": _take_top_ids(player, look), "take_left": take}
			_set_pending(state, ctx, "pick_card", controller, _pick_options(state, data), data)
			return false

		"pump":
			for slot in _slots_for(ctx, effect):
				var card := _battlefield_card(state, slot.get("card", -1))
				if card:
					card.temp_power_bonus += int(effect.get("power", 0))
					card.temp_toughness_bonus += int(effect.get("toughness", 0))

		"pump_self":
			if source:
				source.temp_power_bonus += int(effect.get("power", 0))
				source.temp_toughness_bonus += int(effect.get("toughness", 0))

		"grant_keyword":
			for slot in _slots_for(ctx, effect):
				var card := _battlefield_card(state, slot.get("card", -1))
				if card and not card.temp_keywords.has(effect["keyword"]):
					card.temp_keywords.append(effect["keyword"])

		"counter_unless_pays":
			for slot in _slots_for(ctx, effect):
				var item := _stack_item(state, slot.get("card", -1))
				if item.is_empty():
					continue
				var payer: int = item["controller"]
				var cost := CardDatabase.parse_mana_cost(effect.get("cost", "{0}"))
				if Costs.can_pay_with_taps(state, payer, cost):
					var data := {"payer": payer, "cost": cost, "spell": slot["card"]}
					var options := [
						{"label": "Pay %s" % Costs.to_text(cost), "pay": true},
						{"label": "Don't pay — %s is countered" % _name(state, slot["card"]), "pay": false},
					]
					_set_pending(state, ctx, "pay_or_not", payer, options, data)
					return false
				counter_spell(state, slot["card"])

		"bounce":
			for slot in _slots_for(ctx, effect):
				var card := _battlefield_card(state, slot.get("card", -1))
				if card == null:
					continue
				var was_controlled := card.controller_id == controller
				_remove_from_battlefield(state, card)
				if not card.definition.is_token:
					state.players[card.owner_id].hand.append(card)
				if was_controlled and effect.get("draw_if_controlled", false):
					player.draw_card()

		"create_token":
			var def := CardLibrary.token_definition(effect.get("token", ""))
			if def:
				var token := CardInstance.new(state.next_instance_id, def, controller)
				state.next_instance_id += 1
				token.summoned_this_turn = true
				player.battlefield.append(token)
				Triggers.on_event(state, "etb", {"card": token.instance_id})

		"return_from_graveyard":
			for slot in _slots_for(ctx, effect):
				var card := _take_from_list(player.graveyard, slot.get("card", -1))
				if card:
					player.hand.append(card)

		"become_land_until_your_next_turn":
			if source:
				source.is_land_until_next_turn = true

		"level_up":
			if source:
				source.class_level += 1
				Triggers.on_event(state, "level_up", {"card": source.instance_id, "level": source.class_level})

		_:
			push_warning("Effects: unknown effect type '%s'" % str(effect.get("type", "")))

	return true


static func _complete(state: MTGGameState, ctx: Dictionary) -> void:
	if ctx.get("on_complete", "") == "spell_to_graveyard":
		var item := _stack_item(state, ctx["source"])
		if not item.is_empty():
			state.stack.erase(item)
			var card: CardInstance = item["card"]
			state.players[card.owner_id].graveyard.append(card)
	cease_tokens(state)


# ───────────────────────────── Shared helpers ─────────────────────────────

## Taps lands as needed and spends the cost. Returns false if it can't be paid.
static func pay_cost(state: MTGGameState, player_id: int, cost: Dictionary) -> bool:
	var player := state.players[player_id]
	if not player.has_mana_available(cost):
		var plan := Costs.plan_land_taps(state, player_id, cost)
		if not plan["possible"]:
			return false
		for tap in plan["actions"]:
			var land := _battlefield_card(state, tap.card_instance_id)
			if land:
				land.tapped = true
				player.add_mana(tap.mana_color, 1)
	return player.spend_mana(cost)


static func counter_spell(state: MTGGameState, card_id: int) -> void:
	var item := _stack_item(state, card_id)
	if item.is_empty():
		return
	state.stack.erase(item)
	var card: CardInstance = item["card"]
	if not card.definition.is_token:
		state.players[card.owner_id].graveyard.append(card)


## Tokens that left the battlefield cease to exist.
static func cease_tokens(state: MTGGameState) -> void:
	for p in state.players:
		for zone in [p.hand, p.graveyard, p.exile, p.library]:
			for i in range(zone.size() - 1, -1, -1):
				if zone[i].definition and zone[i].definition.is_token:
					zone.remove_at(i)


static func describe_slots(state: MTGGameState, slots: Array, empty_text: String = "") -> String:
	if slots.is_empty():
		return empty_text
	var names: PackedStringArray = []
	for slot in slots:
		if slot.has("player"):
			names.append("P%d" % slot["player"])
		else:
			names.append(_name(state, slot["card"]))
	return ", ".join(names)


static func _slots_for(ctx: Dictionary, effect: Dictionary) -> Array:
	var spec_index: int = effect.get("target", -1)
	var result: Array = []
	for slot in ctx["targets"]:
		if spec_index == -1 or int(slot.get("spec", 0)) == spec_index:
			result.append(slot)
	return result


static func _battlefield_card(state: MTGGameState, card_id: int) -> CardInstance:
	for p in state.players:
		for card in p.battlefield:
			if card.instance_id == card_id:
				return card
	return null


static func _stack_item(state: MTGGameState, card_id: int) -> Dictionary:
	for item in state.stack:
		if item["card"].instance_id == card_id:
			return item
	return {}


static func _remove_from_battlefield(state: MTGGameState, card: CardInstance) -> void:
	for p in state.players:
		var idx := p.battlefield.find(card)
		if idx != -1:
			p.battlefield.remove_at(idx)
			return


static func _take_from_list(list: Array, card_id: int) -> CardInstance:
	for i in range(list.size()):
		if list[i].instance_id == card_id:
			var card: CardInstance = list[i]
			list.remove_at(i)
			return card
	return null


static func _take_top_ids(player: MTGPlayer, count: int) -> Array:
	# Library top is the END of the array (draw_card uses pop_back).
	var ids: Array = []
	for i in range(count):
		ids.append(player.library[player.library.size() - 1 - i].instance_id)
	return ids


static func _finish_scry(state: MTGGameState, controller: int, data: Dictionary) -> void:
	var player := state.players[controller]
	var kept: Array = []
	var bottom: Array = []
	for id in data["kept"]:
		kept.append(_take_from_list(player.library, id))
	for id in data["bottom"]:
		bottom.append(_take_from_list(player.library, id))
	# Kept cards return on top in the original order; bottomed cards keep their order too.
	for i in range(kept.size() - 1, -1, -1):
		if kept[i]:
			player.library.append(kept[i])
	for card in bottom:
		if card:
			player.library.push_front(card)


static func _scry_options(state: MTGGameState, data: Dictionary) -> Array:
	var name := _name(state, data["cards"][data["index"]])
	return [
		{"label": "Keep %s on top" % name, "keep": true},
		{"label": "Put %s on the bottom" % name, "keep": false},
	]


static func _pick_options(state: MTGGameState, data: Dictionary) -> Array:
	var options: Array = []
	for card_id in data["cards"]:
		options.append({"label": "Take %s" % _name(state, card_id), "card": card_id})
	return options


static func _set_pending(state: MTGGameState, ctx: Dictionary, kind: String, player: int, options: Array, data: Dictionary) -> void:
	state.pending_choice = {"kind": kind, "player": player, "options": options, "ctx": ctx, "data": data}


static func _name(state: MTGGameState, card_id: int) -> String:
	var card := state.find_card_instance(card_id)
	return card.definition.card_name if card and card.definition else "card #%d" % card_id
