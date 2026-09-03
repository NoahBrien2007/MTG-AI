class_name PolicySearchAgent
extends PolicyAgent

## The policy proposes, the search disposes.
##
## Built from three things this project actually measured rather than assumed:
##
##  * The policy's top-3 contains the move a strong player makes 97.4% of the
##    time, but its top-1 only 87.7% — it is a far better filter than picker.
##  * GreedyAgent's formula is a poor judge of a position in the abstract
##    (0.656 AUC, and inverted before turn 7) but a good judge of which of two
##    neighbouring moves is better, which is the only comparison a search makes.
##  * Resolving the stack before judging is worth about 17 points on its own.
##
## So: the network narrows thirty candidates to four, and the hand-written
## evaluator searches those four properly, several plies deep. Four moves at
## depth 3 costs less than thirty at depth 1, which is why this can afford to
## look further than any agent here has so far. One network call per decision,
## at the root only — everything below it is local.

## Root moves taken from the policy. Four covers the top-3 that holds the right
## move 97.4% of the time, plus one.
const POLICY_TOP_K := 4
## Replies considered per node below the root, ranked by the mover's own
## formula. Deep search is made slow by bad move lists, not by depth.
const BRANCH := 6
## Terminal scores, on the same scale GreedyAgent's evaluation uses.
const WIN := 10000.0
const LOSS := -10000.0

## Plies below the root. 1 = judge after the opponent's best reply; 2 = after my
## answer to it. Cost multiplies by BRANCH each step.
var search_depth := 2
var nodes_searched := 0

var _helper: GreedyAgent = null


func _init(id: int = 0) -> void:
	super._init(id)
	agent_name = "PolicySearchAgent"


func choose_action(state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null
	if legal_actions.size() == 1:
		return legal_actions[0]
	if offline:
		return super.choose_action(state, legal_actions)

	var scores := policy_scores(state, legal_actions)
	if scores.is_empty():
		# policy_scores() has already warned and set offline, so the parent
		# delegates straight to GreedyAgent without asking the server again.
		return super.choose_action(state, legal_actions)

	var order: Array[int] = []
	for i in range(scores.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return scores[a] > scores[b])

	# The policy's own favourite is the fallback, so a search that somehow
	# evaluates nothing still plays a sensible move.
	var best_action: MTGAction = legal_actions[order[0]]
	var best_value := -INF
	for i in order.slice(0, mini(POLICY_TOP_K, order.size())):
		var after := _settle(rules_engine.apply_action(state, legal_actions[i]))
		var value := _search(after, search_depth)
		if value > best_value:
			best_value = value
			best_action = legal_actions[i]
	return best_action


## Minimax value of `state` from this agent's seat, in GreedyAgent's units.
func _search(state: MTGGameState, depth: int) -> float:
	nodes_searched += 1
	if state.game_over:
		if state.winner_id == player_id:
			return WIN
		return 0.0 if state.winner_id == -1 else LOSS
	if depth <= 0:
		# _evaluate_state is always from this agent's seat, whoever is to move.
		return _evaluate_state(state)

	var mover := state.acting_player()
	if _helper == null:
		_helper = GreedyAgent.new(mover)
	_helper.player_id = mover

	var plans := _helper._plans(state, rules_engine.get_legal_actions(state))
	if plans.is_empty():
		return _evaluate_state(state)

	# Simulate every reply once, then keep the few the mover would actually
	# consider — ranked by their own formula, not mine.
	var settled: Array[MTGGameState] = []
	var ranked: Array[float] = []
	for plan in plans:
		var simulated := state
		for action in plan:
			simulated = rules_engine.apply_action(simulated, action)
		var leaf := _settle(simulated)
		settled.append(leaf)
		ranked.append(_helper._evaluate_state(leaf))

	var order: Array[int] = []
	for i in range(settled.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return ranked[a] > ranked[b])

	var maximising := mover == player_id
	var best := -INF if maximising else INF
	for i in order.slice(0, mini(BRANCH, order.size())):
		var value := _search(settled[i], depth - 1)
		best = maxf(best, value) if maximising else minf(best, value)
	return best
