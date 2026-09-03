class_name PolicyAgent
extends GreedyAgent

## Plays the move the network believes a strong player would play.
##
##   cd ai/python && python -m mtgai.policy
##   python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt
##
## No search at all, unlike ValueNetAgent. The policy was trained on exactly
## this question — given these legal actions, which one did the recorded agent
## take — so it answers it in a single forward pass, and the state is encoded
## once per decision instead of once per candidate. That also makes it far
## cheaper than the value net was: one small request per decision.
##
## Its ceiling is the strength of whoever recorded the games. Going past that
## needs search on top — but a policy is what makes search affordable, by
## saying which two or three moves are worth looking at out of thirty.
##
## Falls back to the inherited GreedyAgent search if the server goes away, so a
## long series never dies half-way — but check the log for that warning before
## trusting a result, since those games measure Greedy.

var offline := false
var decisions := 0
## Scores behind the most recent decision, in legal-action order. For diagnostics.
var last_scores := PackedFloat32Array()

var net := NetClient.new()


func _init(id: int = 0) -> void:
	super._init(id)
	agent_name = "PolicyAgent"


func choose_action(state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null
	# A forced move is not a decision — the network never trained on one, and
	# asking costs a round trip to be told the only thing that was possible.
	if legal_actions.size() == 1:
		return legal_actions[0]
	if offline:
		return super.choose_action(state, legal_actions)

	var scores := policy_scores(state, legal_actions)
	if scores.is_empty():
		return super.choose_action(state, legal_actions)
	var best := 0
	for i in range(1, scores.size()):
		if scores[i] > scores[best]:
			best = i
	return legal_actions[best]


## One logit per legal action, in the order they were offered. Empty means the
## server failed, and the agent has already marked itself offline.
func policy_scores(state: MTGGameState, legal_actions: Array[MTGAction]) -> PackedFloat32Array:
	var encoded := StateEncoder.encode(state, player_id)
	var features: PackedFloat32Array = encoded["features"]
	var card_ids: PackedInt32Array = encoded["card_ids"]

	# The actions go over in exactly the order they were offered, which is the
	# order `chosen` indexed into when the games were recorded.
	var packed := PackedFloat32Array()
	for action in legal_actions:
		packed.append_array(StateEncoder.encode_action(action, state, player_id))

	var response = net.post_json("/policy", {"states": [{
		"f": Marshalls.raw_to_base64(features.to_byte_array()),
		"ids": Marshalls.raw_to_base64(card_ids.to_byte_array()),
		"a": Marshalls.raw_to_base64(packed.to_byte_array()),
		"n": legal_actions.size(),
	}]})

	var scores := _scores_from(response, legal_actions.size())
	if scores.is_empty():
		offline = true
		var message := "PolicyAgent: no answer from %s — falling back to the hand-written " % net.url("/policy")
		message += "search. Start it with: cd ai/python && python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt"
		push_warning(message)
		print(message)
		return scores

	decisions += 1
	last_scores = scores
	return scores


func _scores_from(response: Variant, expected: int) -> PackedFloat32Array:
	var scores := PackedFloat32Array()
	if not (response is Dictionary) or not response.has("scores"):
		return scores
	var rows: Array = response["scores"]
	if rows.is_empty():
		return scores
	var row: Array = rows[0]
	if row.size() != expected:
		return scores
	for value in row:
		scores.append(float(value))
	return scores


## True when the server answers, has a policy loaded, and agrees with this
## build's encoder. Checked before a series so a mismatch is a clear message
## rather than silently wrong play.
func health_check() -> Dictionary:
	var response = net.get_json("/health")
	if not (response is Dictionary) or not response.get("ok", false):
		return {"ok": false, "error": "no server on %s" % net.url()}
	if not response.get("policy", false):
		return {"ok": false, "error": "the server has no policy — restart it with --policy-checkpoint"}
	var served := int(response.get("feature_count", 0))
	var expected := StateEncoder.feature_count()
	if served != expected:
		return {
			"ok": false,
			"error": "encoding mismatch: the model expects %d features, this build encodes %d — retrain" % [served, expected],
		}
	return {"ok": true, "feature_count": served, "vocab_size": int(response.get("vocab_size", 0))}
