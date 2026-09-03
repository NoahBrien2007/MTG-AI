class_name HumanAgent
extends BaseAgent

## An agent driven by the player through the UI.
##
## It implements the exact same interface as the AI agents: the game session
## asks it for one MTGAction out of the legal list. The difference is that
## choose_action() suspends until the UI calls submit(). That keeps the human
## and the AI on identical footing — anything the player can do here is an
## action an AI agent could also return.

## Emitted (deferred) when the player has to make a decision.
signal decision_requested(state: MTGGameState, legal_actions: Array[MTGAction])
## Emitted once a decision has been made (by the player or automatically).
signal decision_resolved(action: MTGAction)

signal _action_submitted(action: MTGAction)

## Automatically pass priority when there is nothing meaningful to do.
var auto_pass: bool = true

## True when the last returned action was picked without player input.
var last_choice_was_automatic: bool = false
var is_waiting: bool = false

var legal_actions: Array[MTGAction] = []

var _state: MTGGameState
var _queue: Array[MTGAction] = []
var _engine := MTGRulesEngine.new()


func _init(id: int = 0) -> void:
	super._init(id, "Human")


func choose_action(state: MTGGameState, legal: Array[MTGAction]) -> MTGAction:
	_state = state
	legal_actions = legal

	# 1. Queued follow-up actions (e.g. tapping lands before a cast)
	while not _queue.is_empty():
		var queued: MTGAction = _queue.pop_front()
		var found := _find_legal(queued)
		if found != null:
			last_choice_was_automatic = false
			return found
		_queue.clear()

	# 2. Decisions that are no real decision
	var automatic := _automatic_choice(state, legal)
	if automatic != null:
		last_choice_was_automatic = true
		return automatic

	# 3. Wait for the UI
	is_waiting = true
	last_choice_was_automatic = false
	# Deferred so a UI that answers synchronously can never race the await below.
	call_deferred("_emit_decision_requested", state, legal)
	var chosen: MTGAction = await _action_submitted
	is_waiting = false
	decision_resolved.emit(chosen)
	return chosen


## Submit a single action. Returns false if it is not legal right now.
func submit(action: MTGAction) -> bool:
	if not is_waiting or action == null:
		return false
	var found := _find_legal(action)
	if found == null and _engine.is_action_legal(_state, action):
		found = action
	if found == null:
		_queue.clear()
		return false
	_action_submitted.emit(found)
	return true


## Submit a sequence: the first action is played now, the rest are queued and
## re-validated one by one as the game asks for the next decision.
func submit_sequence(actions: Array[MTGAction]) -> bool:
	if actions.is_empty() or not is_waiting:
		return false
	_queue.clear()
	for i in range(1, actions.size()):
		_queue.append(actions[i])
	return submit(actions[0])


func find_legal(action_type: MTGAction.ActionType, card_instance_id: int = -1) -> MTGAction:
	for legal in legal_actions:
		if legal.action_type == action_type and (card_instance_id == -1 or legal.card_instance_id == card_instance_id):
			return legal
	return null


func _emit_decision_requested(state: MTGGameState, legal: Array[MTGAction]) -> void:
	decision_requested.emit(state, legal)


func _find_legal(action: MTGAction) -> MTGAction:
	for legal in legal_actions:
		if legal.equals(action):
			return legal
	return null


func _automatic_choice(state: MTGGameState, legal: Array[MTGAction]) -> MTGAction:
	# Exactly one option that is not "pass": nothing to decide (e.g. no creatures to attack with).
	if legal.size() == 1 and legal[0].action_type != MTGAction.ActionType.PASS_PRIORITY:
		return legal[0]

	if auto_pass and _nothing_worth_doing(state, legal):
		for action in legal:
			if action.action_type == MTGAction.ActionType.PASS_PRIORITY:
				return action
	return null


## True when the only options are passing or tapping lands and no spell in hand
## could be cast even after tapping.
func _nothing_worth_doing(state: MTGGameState, legal: Array[MTGAction]) -> bool:
	for action in legal:
		if action.action_type != MTGAction.ActionType.PASS_PRIORITY \
				and action.action_type != MTGAction.ActionType.TAP_LAND:
			return false

	var player := state.players[player_id]
	for card in player.hand:
		if not card.definition or card.definition.card_type == CardDefinition.CardType.LAND:
			continue
		if _engine.is_cast_timing_legal(state, player_id, card) \
				and Costs.can_pay_with_taps(state, player_id, Costs.cast_cost(state, card, player_id, false)):
			return false
	# Abilities we could afford (e.g. levelling a Class) are worth a look too.
	for card in player.battlefield:
		for ability in _engine.get_ability_actions(state, player_id, card, false):
			var cost := _engine.ability_cost(card, ability.ability_index)
			if Costs.can_pay_with_taps(state, player_id, cost):
				return false
	return true
