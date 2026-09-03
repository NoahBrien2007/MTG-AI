extends SceneTree

## Shows what ValueNetAgent actually does, decision by decision, instead of
## leaving you to infer it from a win rate.
##
##   cd ai/python && python -m mtgai.serve --checkpoint checkpoints/B/value_net.pt
##   godot --headless -s tests/diagnose_value_net.gd
##
## Three things it answers:
##
##  1. Is the model coherent about sides? Scoring one position from both seats
##     should give two numbers that sum to about 1.0. Far from that and the
##     model is not judging the position, it is judging something else — most
##     likely "whoever is about to act tends to win".
##  2. Does the agent actually play? Pass-priority rate and lands played, next
##     to Greedy on the same seeds as a control. An agent that passes far more
##     than Greedy is paralysed, whatever its validation AUC says.
##  3. Can the model tell candidates apart? The spread between its best and
##     worst option per decision. If that is down at the noise floor the search
##     has nothing to steer by, and the agent is playing at random.

const DECK := "res://data/decks/botboys_deck_izzet.txt"
const GAMES := 4

var _agent: BaseAgent
var _decisions := 0
var _passes := 0
var _lands := 0
var _spread_sum := 0.0
var _spread_n := 0
var _shown := 0
var _captured: MTGGameState = null


func _init() -> void:
	print("--- ValueNetAgent diagnostic ---")
	var probe := ValueNetAgent.new(0)
	var health := probe.health_check()
	if not health.get("ok", false):
		print("server unreachable: %s" % health.get("error", "?"))
		print("start it with: cd ai/python && python -m mtgai.serve --checkpoint checkpoints/B/value_net.pt")
		quit(1)
		return
	print("server  : %d features, %d cards" % [health["feature_count"], health["vocab_size"]])
	print("encoder : %d features" % StateEncoder.feature_count())

	_probe_perspective(probe)

	print("\n== Greedy on seat 0 (control) ==")
	_run_series("greedy")
	print("\n== ValueNet on seat 0 ==")
	_run_series("valuenet")
	print("\n--- done ---")
	quit(0)


## Scores one mid-game position from both seats. P(player 0 wins) and
## P(player 1 wins) describe the same position, so they should sum to ~1.
func _probe_perspective(probe: ValueNetAgent) -> void:
	var session := GameSession.new()
	session.setup(DECK, DECK, GreedyAgent.new(0), GreedyAgent.new(1), 777)
	session.decision_made.connect(_capture_state)
	session.run_sync()
	if _captured == null:
		print("\n(no mid-game state captured — skipping the perspective probe)")
		return

	var payload: Array = []
	for seat in [0, 1]:
		payload.append(ValueNetAgent.payload_for(_captured, seat))
	var values := probe._post_values(payload)
	if values.size() != 2:
		print("\nperspective probe failed (no answer from the server)")
		return

	var total: float = float(values[0]) + float(values[1])
	print("\nperspective probe (turn %d, one position seen from both seats)" % _captured.turn_number)
	print("  P(seat 0 wins) = %.3f   P(seat 1 wins) = %.3f   sum = %.3f" % [values[0], values[1], total])
	if absf(total - 1.0) > 0.25:
		print("  [!] far from 1.0 — the model is not scoring the position, it is")
		print("      scoring something about the encoding itself.")


func _capture_state(state: MTGGameState, _legal: Array[MTGAction], _chosen: int) -> void:
	# One board with something on it, mid-game.
	if _captured == null and state.turn_number >= 6:
		_captured = state.duplicate_state()


func _run_series(kind: String) -> void:
	_decisions = 0
	_passes = 0
	_lands = 0
	_spread_sum = 0.0
	_spread_n = 0
	_shown = 0
	var wins := 0

	for i in range(GAMES):
		_agent = ValueNetAgent.new(0) if kind == "valuenet" else GreedyAgent.new(0)
		var session := GameSession.new()
		session.max_actions = 3000
		# Same seeds for both agents, so the comparison is like for like.
		session.setup(DECK, DECK, _agent, GreedyAgent.new(1), 500 + i, i % 2)
		session.decision_made.connect(_on_decision)
		var final_state := session.run_sync()
		if final_state.winner_id == 0:
			wins += 1
		if _agent is ValueNetAgent and (_agent as ValueNetAgent).offline:
			print("  [!] the server stopped answering — the rest of this run was the fallback")

	print("  won %d/%d" % [wins, GAMES])
	print("  decisions      %d" % _decisions)
	print("  pass priority  %d (%.1f%%)" % [_passes, 100.0 * _passes / maxi(_decisions, 1)])
	print("  lands played   %d (%.1f per game)" % [_lands, float(_lands) / GAMES])
	if _spread_n > 0:
		print("  mean spread between best and worst candidate: %.4f" % (_spread_sum / _spread_n))


func _on_decision(state: MTGGameState, legal: Array[MTGAction], chosen: int) -> void:
	if state.acting_player() != 0:
		return
	_decisions += 1
	var action := legal[chosen]
	if action.action_type == MTGAction.ActionType.PASS_PRIORITY:
		_passes += 1
	elif action.action_type == MTGAction.ActionType.PLAY_LAND:
		_lands += 1

	if not (_agent is ValueNetAgent):
		return
	var values: PackedFloat32Array = (_agent as ValueNetAgent).last_values
	if values.size() < 2:
		return

	var lo: float = values[0]
	var hi: float = values[0]
	for v in values:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_spread_sum += hi - lo
	_spread_n += 1
	if _shown < 12:
		_shown += 1
		# The agent takes the argmax, so the best score is the one it acted on.
		print("  turn %2d  %2d options  spread %.4f  best %.3f  ->  %s" % [
			state.turn_number, values.size(), hi - lo, hi, action.signature(),
		])
