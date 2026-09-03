class_name ValueNetAgent
extends GreedyAgent

## GreedyAgent's search with the hand-written scoring formula replaced by a
## trained value network.
##
## The search itself is unchanged and inherited: enumerate every plan (taps… +
## cast), simulate each one to the state it produces, keep the best. Only the
## judgement of "best" moves from W_LIFE/W_BOARD_POWER/… to
## P(this player wins from here), as learned from recorded games.
##
## Start the server first:
##     cd ai/python && python -m mtgai.serve
##
## Every candidate state of one decision goes in a single POST. A searching
## agent scores dozens of states per decision, and on loopback the round trip
## costs far more than the model does, so one request per state would make the
## agent slower than the network is smart.
##
## GameSession.run_sync() drives a whole game inside one call, so this has to
## block: HTTPRequest is a Node and needs the scene tree to pump it, which never
## gets a frame here. Hence the raw HTTPClient poll loop below.
##
## If the server cannot be reached the agent says so once and finishes the run
## on the inherited heuristic, so a series never dies half-way — but check for
## that warning before believing a result, since those games measure Greedy.

const ENDPOINT := "/value"
## Generous: a cold first request pays for torch's lazy CUDA/BLAS setup.
const TIMEOUT_MS := 10000
## Divides GreedyAgent's unbounded score before the logistic that maps it onto
## 0-1, so the two evaluations are on a comparable scale before mixing.
const HEURISTIC_SCALE := 40.0
## Depth-2 search widths. The network is the better judge but costs a round
## trip, so the cheap hand-written formula picks WHICH lines are worth looking
## at and the network says which is actually good — each doing the job it
## measurably wins at.
const SEARCH_TOP_K := 4
const REPLY_TOP_K := 12

var host := "127.0.0.1"
var port := 8787
## How much of the decision the network makes: 1.0 is pure value net, 0.0 is
## GreedyAgent's hand-written formula, anything between is a mix. A first value
## net is usually worse than the heuristic at fine tactical choices but better
## at judging the position, so the mix can beat either alone — and sweeping it
## says how much the model actually knows: if no setting above 0 helps, the
## problem is the data, not the search.
var blend := 1.0
## 1 = judge the position straight after my move. 2 = let the opponent reply
## first, and take the value of their best answer. At 1 ply the gap between two
## candidate moves is smaller than the network's own error, so the choice is
## mostly noise; a reply deep enough to change the board makes the differences
## bigger than the noise, which is the whole reason to have a value function.
var search_depth := 2
## True once the server has failed us; we stop retrying and fall back.
var offline := false
var requests_made := 0
var states_scored := 0
## The scores behind the most recent decision, for diagnostics — one per plan,
## in the same order as the plans considered.
var last_values := PackedFloat32Array()

var _client := HTTPClient.new()
## Borrowed to enumerate and rank the opponent's replies; its player_id is
## pointed at whoever is to move.
var _helper: GreedyAgent = null


func _init(id: int = 0) -> void:
	super._init(id)
	agent_name = "ValueNetAgent"


func choose_action(state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null
	if offline:
		return super.choose_action(state, legal_actions)

	var plans := _plans(state, legal_actions)
	var outcomes: Array[MTGGameState] = []
	for plan in plans:
		var simulated := state
		for action in plan:
			simulated = rules_engine.apply_action(simulated, action)
		outcomes.append(_settle(simulated))

	var scores := _score_states(outcomes) if blend > 0.0 else PackedFloat32Array()
	if blend <= 0.0:
		# Pure heuristic, but over the same settled states the network sees —
		# the control that separates a plumbing bug from a model that is simply
		# not good enough. This should be a coin flip against GreedyAgent.
		scores.resize(outcomes.size())
		for i in range(outcomes.size()):
			scores[i] = _heuristic_probability(outcomes[i])
	elif not scores.is_empty() and blend < 1.0:
		for i in range(outcomes.size()):
			scores[i] = blend * scores[i] + (1.0 - blend) * _heuristic_probability(outcomes[i])
	if not scores.is_empty() and search_depth >= 2 and blend > 0.0 and scores.size() > 1:
		scores = _deepen(outcomes, scores)
	if scores.is_empty():
		offline = true
		var message := "ValueNetAgent: no answer from http://%s:%d%s — falling back to the " % [host, port, ENDPOINT]
		message += "hand-written evaluation. Start it with: cd ai/python && python -m mtgai.serve"
		push_warning(message)
		print(message)
		return super.choose_action(state, legal_actions)

	# Strictly greater, like GreedyAgent: ties go to the earlier plan, and
	# PASS_PRIORITY is first in the legal list, so a line that merely matches
	# passing is never played.
	var best := 0
	for i in range(1, scores.size()):
		if scores[i] > scores[best]:
			best = i
	return plans[best][0]


## Re-scores the most promising candidates one ply deeper: the opponent answers,
## and a line is worth what it is worth after their best reply.
##
## Only the top few candidates are expanded, and their depth-2 values are not
## comparable with the untouched 1-ply scores of the rest (a value that has
## survived a reply is pessimistic by comparison), so the unexpanded ones are
## pushed out of contention rather than left to win the argmax by flattery.
## Returns empty if the server fails.
func _deepen(outcomes: Array[MTGGameState], scores: PackedFloat32Array) -> PackedFloat32Array:
	var order: Array[int] = []
	for i in range(scores.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return scores[a] > scores[b])

	var deep := PackedFloat32Array()
	deep.resize(scores.size())
	for i in range(deep.size()):
		deep[i] = -1.0

	var payload: Array = []
	var leaves: Array[MTGGameState] = []
	var owner: PackedInt32Array = []
	var actors: PackedInt32Array = []

	for candidate in order.slice(0, mini(SEARCH_TOP_K, order.size())):
		var after: MTGGameState = outcomes[candidate]
		if after.game_over:
			deep[candidate] = scores[candidate]
			continue
		var actor := after.acting_player()
		if _helper == null:
			_helper = GreedyAgent.new(actor)
		_helper.player_id = actor

		# Every reply, simulated and settled the same way my own moves are.
		var settled: Array[MTGGameState] = []
		var ranked: Array[float] = []
		for plan in _helper._plans(after, rules_engine.get_legal_actions(after)):
			var simulated := after
			for action in plan:
				simulated = rules_engine.apply_action(simulated, action)
			var leaf := _settle(simulated)
			settled.append(leaf)
			# Ranked by the mover's own formula: a bad move list is what makes
			# deep search slow instead of strong.
			ranked.append(_helper._evaluate_state(leaf))

		if settled.is_empty():
			deep[candidate] = scores[candidate]
			continue

		var reply_order: Array[int] = []
		for i in range(settled.size()):
			reply_order.append(i)
		reply_order.sort_custom(func(a: int, b: int) -> bool: return ranked[a] > ranked[b])

		for i in reply_order.slice(0, mini(REPLY_TOP_K, reply_order.size())):
			var leaf: MTGGameState = settled[i]
			if leaf.game_over:
				# No need to ask about a decided game.
				var settled_value := 1.0 if leaf.winner_id == player_id else (0.5 if leaf.winner_id == -1 else 0.0)
				_fold(deep, candidate, settled_value, actor)
				continue
			var leaf_actor := leaf.acting_player()
			payload.append(payload_for(leaf, leaf_actor))
			leaves.append(leaf)
			owner.append(candidate)
			actors.append(leaf_actor)

	if payload.is_empty():
		return deep

	var values := _post_values(payload)
	if values.size() != payload.size():
		return PackedFloat32Array()
	states_scored += payload.size()
	for j in range(payload.size()):
		var value := float(values[j])
		var mine: float = value if actors[j] == player_id else 1.0 - value
		if blend < 1.0:
			mine = blend * mine + (1.0 - blend) * _heuristic_probability(leaves[j])
		# Whoever is to move at the parent picks the reply that suits them.
		_fold(deep, owner[j], mine, outcomes[owner[j]].acting_player())
	return deep


## Minimax fold: my own move keeps the best line, the opponent's keeps the worst
## for me. -1.0 marks a candidate nothing has been folded into yet.
func _fold(deep: PackedFloat32Array, candidate: int, value: float, mover: int) -> void:
	if deep[candidate] < 0.0:
		deep[candidate] = value
	elif mover == player_id:
		deep[candidate] = maxf(deep[candidate], value)
	else:
		deep[candidate] = minf(deep[candidate], value)


## One state, packed for the server.
##
## The feature vector goes over as base64 of its raw float32 bytes rather than
## 1295 JSON numbers. Formatting those numbers in GDScript — and building the
## Variant array to hold them — cost far more than the model spends thinking,
## and it is what made a measurement run take minutes per game.
static func payload_for(state: MTGGameState, viewer: int) -> Dictionary:
	var encoded := StateEncoder.encode(state, viewer)
	var features: PackedFloat32Array = encoded["features"]
	var card_ids: PackedInt32Array = encoded["card_ids"]
	return {
		"f": Marshalls.raw_to_base64(features.to_byte_array()),
		"ids": Marshalls.raw_to_base64(card_ids.to_byte_array()),
	}


## GreedyAgent's score squashed onto 0-1, so it can be mixed with a probability.
func _heuristic_probability(state: MTGGameState) -> float:
	return 1.0 / (1.0 + exp(-_evaluate_state(state) / HEURISTIC_SCALE))


## P(this agent wins) for each state. Empty means the server failed.
##
## Every state is encoded from the point of view of whoever is about to act in
## it, and the answer is flipped when that is the opponent. This is not a
## stylistic choice — it is what keeps the query inside the training
## distribution. GameRecorder always encodes from the acting player's seat, so
## the "acting player is me" feature is a constant 1.0 in every recorded sample;
## the model has never seen it be 0.0, and the arbitrary weight that settles on
## a constant feature would otherwise swing the comparison between candidates by
## an amount unrelated to the position — and it swings it exactly between
## passing (priority goes to the opponent) and acting (priority stays), which is
## the one comparison that decides whether the agent plays the game at all.
func _score_states(states: Array[MTGGameState]) -> PackedFloat32Array:
	var scores := PackedFloat32Array()
	scores.resize(states.size())

	var payload: Array = []
	var pending: PackedInt32Array = []
	var actors: PackedInt32Array = []
	for i in range(states.size()):
		var state := states[i]
		if state.game_over:
			# A decided game needs no model, and asking about one would feed it
			# states its training data never contains.
			scores[i] = 1.0 if state.winner_id == player_id else (0.5 if state.winner_id == -1 else 0.0)
			continue
		var actor := state.acting_player()
		payload.append(payload_for(state, actor))
		pending.append(i)
		actors.append(actor)

	if payload.is_empty():
		last_values = scores
		return scores

	var values := _post_values(payload)
	if values.size() != payload.size():
		return PackedFloat32Array()
	for j in range(pending.size()):
		# The server answers P(the acting player wins); we want P(I win).
		var value := float(values[j])
		scores[pending[j]] = value if actors[j] == player_id else 1.0 - value
	states_scored += payload.size()
	last_values = scores
	return scores


# ───────────────────────────── HTTP ─────────────────────────────

func _post_values(states: Array) -> Array:
	if not _ensure_connected():
		return []

	var body := JSON.stringify({"states": states})
	if _client.request(HTTPClient.METHOD_POST, ENDPOINT, ["Content-Type: application/json"], body) != OK:
		_reset()
		return []

	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if Time.get_ticks_msec() > deadline:
			_reset()
			return []
		OS.delay_msec(1)

	if not _client.has_response() or _client.get_response_code() != 200:
		_reset()
		return []

	var raw := PackedByteArray()
	while _client.get_status() == HTTPClient.STATUS_BODY:
		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(1)
		else:
			raw.append_array(chunk)
		if Time.get_ticks_msec() > deadline:
			_reset()
			return []

	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if not (parsed is Dictionary) or not parsed.has("values"):
		return []
	requests_made += 1
	# serve.py speaks HTTP/1.1, so the connection stays open for the next
	# decision — reconnecting per decision would dominate the cost.
	return parsed["values"]


func _ensure_connected() -> bool:
	var status := _client.get_status()
	if status == HTTPClient.STATUS_CONNECTED:
		return true

	_client.close()
	if _client.connect_to_host(host, port) != OK:
		return false

	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() <= deadline:
		_client.poll()
		status = _client.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			return true
		# CANT_CONNECT / CANT_RESOLVE / DISCONNECTED — nothing is listening.
		if status != HTTPClient.STATUS_CONNECTING and status != HTTPClient.STATUS_RESOLVING:
			return false
		OS.delay_msec(1)
	return false


func _reset() -> void:
	_client.close()


## True when the server answers and its encoding matches this build's encoder.
## Checked once before a series so a mismatch is a clear message instead of
## silently wrong play.
func health_check() -> Dictionary:
	if not _ensure_connected():
		return {"ok": false, "error": "no server on http://%s:%d" % [host, port]}
	if _client.request(HTTPClient.METHOD_GET, "/health", []) != OK:
		_reset()
		return {"ok": false, "error": "request failed"}

	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if Time.get_ticks_msec() > deadline:
			_reset()
			return {"ok": false, "error": "timed out"}
		OS.delay_msec(1)

	var raw := PackedByteArray()
	while _client.get_status() == HTTPClient.STATUS_BODY:
		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(1)
		else:
			raw.append_array(chunk)
		if Time.get_ticks_msec() > deadline:
			_reset()
			return {"ok": false, "error": "timed out"}

	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if not (parsed is Dictionary) or not parsed.get("ok", false):
		return {"ok": false, "error": "unexpected /health response"}
	# A server running only a policy answers /health perfectly well and then
	# 400s every /value — which looks exactly like a working agent that plays
	# like Greedy, because that is the fallback.
	if not parsed.get("value", false):
		return {"ok": false, "error": "the server has no value net — restart it with --checkpoint <path>"}

	var expected := StateEncoder.feature_count()
	var served := int(parsed.get("feature_count", 0))
	if served != expected:
		return {
			"ok": false,
			"error": "encoding mismatch: the model expects %d features, this build encodes %d — retrain, or check ai/training/vocabulary.json" % [served, expected],
		}
	return {"ok": true, "feature_count": served, "vocab_size": int(parsed.get("vocab_size", 0))}
