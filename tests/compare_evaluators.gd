extends SceneTree

## Does the network judge positions better than the formula it replaced?
##
##   cd ai/python && python -m mtgai.serve --checkpoint checkpoints/B/value_net.pt
##   godot --headless -s tests/compare_evaluators.gd
##
## Plays Greedy vs Greedy — the same distribution the model was trained on —
## and at every decision scores the position two ways: GreedyAgent's hand-written
## formula, and the value network. Each score is then judged against what
## actually happened in that game, and both get an AUC: the probability that a
## position the acting player went on to win is ranked above one they lost.
##
## This is the comparison that decides what to do next, and no win rate can make
## it. If the two AUCs are close, the network has learned the formula and
## nothing more, so deeper search would only search a worse evaluator. If the
## network is clearly ahead, its errors are worth filtering with lookahead, and
## 2-3 ply is the next move.
##
## 0.5 is coin-flipping. Late-game rows matter most: every evaluator looks
## uncertain on turn 2, and telling a won board from a lost one is the job.

const DECK := "res://data/decks/botboys_deck_izzet.txt"
const GAMES := 20
const BATCH := 200

var _net: ValueNetAgent
var _greedy: Array[GreedyAgent] = []

var _heuristic := PackedFloat32Array()
var _network := PackedFloat32Array()
var _turns := PackedInt32Array()
var _players := PackedInt32Array()
var _outcomes := PackedFloat32Array()
var _game_start := 0

var _pending: Array = []


func _init() -> void:
	print("--- evaluator comparison: %d games, Greedy vs Greedy ---" % GAMES)
	_net = ValueNetAgent.new(0)
	var health := _net.health_check()
	if not health.get("ok", false):
		print("server unreachable: %s" % health.get("error", "?"))
		quit(1)
		return
	print("server: %d features, %d cards\n" % [health["feature_count"], health["vocab_size"]])

	_greedy = [GreedyAgent.new(0), GreedyAgent.new(1)]

	for i in range(GAMES):
		var session := GameSession.new()
		session.max_actions = 3000
		session.setup(DECK, DECK, GreedyAgent.new(0), GreedyAgent.new(1), 1300 + i, i % 2)
		session.decision_made.connect(_on_decision)
		_game_start = _heuristic.size()
		var final_state := session.run_sync()
		_flush()
		_label_game(final_state)
		print("  game %2d/%d — %d positions" % [i + 1, GAMES, _heuristic.size()])

	print("\n%d positions scored\n" % _heuristic.size())
	print("%-14s %10s %10s" % ["positions", "heuristic", "network"])
	_report("all", 0, 99)
	_report("turns 1-6", 1, 6)
	_report("turns 7-11", 7, 11)
	_report("turns 12+", 12, 99)
	print("\n--- done ---")
	quit(0)


func _on_decision(state: MTGGameState, _legal: Array[MTGAction], _chosen: int) -> void:
	var actor := state.acting_player()
	# Both evaluators see exactly the same position, from the same seat.
	_greedy[actor].player_id = actor
	_heuristic.append(_greedy[actor]._evaluate_state(state))
	_turns.append(state.turn_number)
	_players.append(actor)

	_pending.append(ValueNetAgent.payload_for(state, actor))
	if _pending.size() >= BATCH:
		_flush()


## Scores are appended in the same order the positions were seen, so the two
## arrays stay aligned with _turns and _players.
func _flush() -> void:
	if _pending.is_empty():
		return
	var values := _net._post_values(_pending)
	if values.size() != _pending.size():
		print("  [!] server returned %d values for %d states — aborting" % [values.size(), _pending.size()])
		quit(1)
		return
	for v in values:
		_network.append(float(v))
	_pending.clear()


func _label_game(final_state: MTGGameState) -> void:
	for i in range(_game_start, _heuristic.size()):
		if final_state.winner_id == -1:
			_outcomes.append(0.5)
		else:
			_outcomes.append(1.0 if final_state.winner_id == _players[i] else 0.0)


func _report(label: String, low: int, high: int) -> void:
	var h := PackedFloat32Array()
	var n := PackedFloat32Array()
	var y := PackedFloat32Array()
	for i in range(_outcomes.size()):
		if _turns[i] < low or _turns[i] > high or _outcomes[i] == 0.5:
			continue
		h.append(_heuristic[i])
		n.append(_network[i])
		y.append(_outcomes[i])
	if y.size() < 50:
		print("%-14s %10s %10s  (only %d positions)" % [label, "-", "-", y.size()])
		return
	print("%-14s %10.3f %10.3f  (%d positions)" % [label, _auc(h, y), _auc(n, y), y.size()])


## Mann-Whitney AUC: P(a won position outranks a lost one), ties counted as half.
static func _auc(scores: PackedFloat32Array, labels: PackedFloat32Array) -> float:
	var n := scores.size()
	var order: Array[int] = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool: return scores[a] < scores[b])

	var ranks := PackedFloat32Array()
	ranks.resize(n)
	var i := 0
	while i < n:
		var j := i
		while j + 1 < n and is_equal_approx(scores[order[j + 1]], scores[order[i]]):
			j += 1
		var average := (i + j) / 2.0 + 1.0
		for k in range(i, j + 1):
			ranks[order[k]] = average
		i = j + 1

	var positives := 0.0
	var negatives := 0.0
	var rank_sum := 0.0
	for idx in range(n):
		if labels[idx] > 0.5:
			positives += 1.0
			rank_sum += ranks[idx]
		else:
			negatives += 1.0
	if positives == 0.0 or negatives == 0.0:
		return 0.5
	return (rank_sum - positives * (positives + 1.0) / 2.0) / (positives * negatives)
