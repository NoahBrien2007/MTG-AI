class_name GreedyAgent
extends BaseAgent

var rules_engine: MTGRulesEngine


func _init(id: int = 0) -> void:
	super._init(id, "GreedyAgent")
	rules_engine = MTGRulesEngine.new()


func choose_action(state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null

	var best_action: MTGAction = legal_actions[0]
	var best_eval: float = -999999.0

	for action in legal_actions:
		var simulated_state := rules_engine.apply_action(state, action)
		var eval_score := _evaluate_state(simulated_state)
		if eval_score > best_eval:
			best_eval = eval_score
			best_action = action

	return best_action


func _evaluate_state(state: MTGGameState) -> float:
	if state.game_over:
		if state.winner_id == player_id:
			return 10000.0
		elif state.winner_id == -1:
			return 0.0
		else:
			return -10000.0

	var my_player := state.players[player_id]
	var opp_player := state.players[1 - player_id]

	var score: float = 0.0

	# 1. Life totals
	score += (my_player.life - opp_player.life) * 10.0

	# 2. Board power presence
	var my_board_power: int = 0
	var my_board_count: int = 0
	for card in my_player.battlefield:
		if card.definition and card.definition.card_type == CardDefinition.CardType.CREATURE:
			my_board_power += card.get_power()
			my_board_count += 1
		elif card.definition and card.definition.card_type == CardDefinition.CardType.LAND:
			score += 2.0

	var opp_board_power: int = 0
	var opp_board_count: int = 0
	for card in opp_player.battlefield:
		if card.definition and card.definition.card_type == CardDefinition.CardType.CREATURE:
			opp_board_power += card.get_power()
			opp_board_count += 1

	score += (my_board_power - opp_board_power) * 5.0
	score += (my_board_count - opp_board_count) * 3.0

	# 3. Card advantage in hand
	score += (my_player.hand.size() - opp_player.hand.size()) * 4.0

	return score
