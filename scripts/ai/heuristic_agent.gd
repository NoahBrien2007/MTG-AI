class_name HeuristicAgent
extends BaseAgent

## Rule-of-thumb agent: scores each legal action with fixed priorities.

var _engine := MTGRulesEngine.new()


func _init(id: int = 0) -> void:
	super._init(id, "HeuristicAgent")


func choose_action(state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null

	var best_action: MTGAction = legal_actions[0]
	var best_score: float = -INF
	for action in legal_actions:
		var score := _evaluate_action(state, action)
		if score > best_score:
			best_score = score
			best_action = action
	return best_action


func _evaluate_action(state: MTGGameState, action: MTGAction) -> float:
	match action.action_type:
		MTGAction.ActionType.PLAY_LAND:
			return 100.0

		MTGAction.ActionType.TAP_LAND:
			# Only worth tapping if it brings a spell in hand within reach.
			return 80.0 if _has_castable_spell(state) else 5.0

		MTGAction.ActionType.CAST_SPELL:
			var card := state.find_card_instance(action.card_instance_id)
			if card == null or card.definition == null:
				return 85.0
			var def := card.definition
			if def.card_type == CardDefinition.CardType.CREATURE:
				return 95.0 + def.power + def.toughness
			# Never aim our own spells at ourselves or our own creatures.
			for slot in action.targets:
				if slot.get("player", -1) == player_id:
					return 1.0
				var target := state.find_card_instance(slot.get("card", -1))
				if target and target.controller_id == player_id and _is_harmful(def):
					return 1.0
			if def.is_permanent():
				return 88.0
			var score := 85.0 + def.mana_value
			if action.kicked:
				score += 3.0
			return score

		MTGAction.ActionType.ACTIVATE_ABILITY:
			return 70.0

		MTGAction.ActionType.CHOOSE:
			return _evaluate_choice(state, action)

		MTGAction.ActionType.DECLARE_ATTACKERS:
			if action.attacker_ids.is_empty():
				return 15.0
			return 90.0 + action.attacker_ids.size() * 5.0

		MTGAction.ActionType.DECLARE_BLOCKER:
			return 75.0

		MTGAction.ActionType.FINISH_COMBAT_DECLARATIONS:
			return 30.0

		MTGAction.ActionType.PASS_PRIORITY:
			return 10.0

	return 0.0


## Damage / tap / bounce / counter spells should not hit our own things.
func _is_harmful(def: CardDefinition) -> bool:
	for effect in def.rules.get("spell", []):
		if effect.get("type", "") in ["damage", "tap", "bounce", "counter_unless_pays"]:
			return true
	return false


## Pending effect decisions: prefer taking cards, keeping good cards, paying for spells.
func _evaluate_choice(state: MTGGameState, action: MTGAction) -> float:
	var pending := state.pending_choice
	if pending.is_empty():
		return 0.0
	var option: Dictionary = pending["options"][action.choice_index]
	match pending["kind"]:
		"pay_or_not":
			return 50.0 if option.get("pay", false) else 10.0
		"scry":
			var card := state.find_card_instance(pending["data"]["cards"][pending["data"]["index"]])
			var lands_in_hand := 0
			for c in state.players[player_id].hand:
				if c.definition and c.definition.is_land():
					lands_in_hand += 1
			var want_land := lands_in_hand < 2
			var is_land := card != null and card.definition != null and card.definition.is_land()
			var keep: bool = option.get("keep", true)
			return 50.0 if keep == (is_land == want_land) else 10.0
		"pick_card":
			var card := state.find_card_instance(option.get("card", -1))
			if card and card.definition:
				return 40.0 + (5.0 if card.definition.is_land() else card.definition.mana_value)
		"targets":
			# Prefer hitting opponent's creatures, avoid our own.
			var score := 20.0
			for slot in option.get("slots", []):
				var target := state.find_card_instance(slot.get("card", -1))
				if target:
					score += 10.0 if target.controller_id != player_id else -15.0
			return score
	return 10.0


func _has_castable_spell(state: MTGGameState) -> bool:
	var player := state.players[player_id]
	for card in player.hand:
		if not card.definition or card.definition.card_type == CardDefinition.CardType.LAND:
			continue
		if _engine.is_cast_timing_legal(state, player_id, card) \
				and Costs.can_pay_with_taps(state, player_id, Costs.cast_cost(state, card, player_id, false)):
			return true
	return false
