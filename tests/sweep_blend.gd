extends SceneTree

## How much does the value network actually know?
##
##   cd ai/python && python -m mtgai.serve --checkpoint checkpoints/B/value_net.pt
##   godot --headless -s tests/sweep_blend.gd
##
## Plays each setting against GreedyAgent and reports the win rate. Two rows are
## controls, and they matter more than the rest:
##
##   greedy    GreedyAgent against itself — must land near 50%. Anything else
##             means the seeds or the seat alternation are unfair.
##   blend 0   ValueNetAgent using GreedyAgent's own formula, over the settled
##             states. Also near 50%, unless the plumbing in ValueNetAgent is
##             broken — which is the difference between "the model is bad" and
##             "my search is bad", and no win rate alone can tell them apart.
##
## Then blend 0.25 … 1.00 mix in the network. If none of them beats the controls,
## the model has no usable signal at the level of choosing a move, and the answer
## is better data rather than more search.

const DECK := "res://data/decks/botboys_deck_izzet.txt"
## Default is a smoke test. Eight games means a standard error of +/-18% on a
## win rate, which cannot tell 45% from 60% — pass a real number for a real
## measurement:  godot --headless -s tests/sweep_blend.gd -- 100
const DEFAULT_GAMES := 8

var games := DEFAULT_GAMES


func _init() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0 and argv[0].is_valid_int():
		games = argv[0].to_int()
	print("--- blend sweep: %d games per setting, opponent is Greedy ---" % games)
	print("    standard error on each rate: +/-%.1f%%" % (100.0 * 0.5 / sqrt(float(games))))
	# Probe once. A row whose model is not loaded is 100 games of the fallback
	# agent wearing the model's name, which is worse than no row at all.
	var has_value: bool = ValueNetAgent.new(0).health_check().get("ok", false)
	var has_policy: bool = PolicyAgent.new(0).health_check().get("ok", false)

	print("%-16s %8s %8s %10s %10s" % ["setting", "wins", "rate", "decisions", "net calls"])
	_measure("greedy", "greedy", 0.0, 1)
	if has_value:
		_measure("value 1-ply", "valuenet", 1.0, 1)
		_measure("value 2-ply", "valuenet", 1.0, 2)
		_measure("value mix 2-ply", "valuenet", 0.5, 2)
	else:
		print("%-16s %8s %8s %10s %10s  (no value net loaded)" % ["value rows", "-", "-", "-", "-"])
	if has_policy:
		_measure("policy", "policy", 0.0, 1)
		_measure("policy+search 1", "policysearch", 0.0, 1)
		_measure("policy+search 2", "policysearch", 0.0, 2)
	else:
		print("%-16s %8s %8s %10s %10s  (no policy loaded)" % ["policy rows", "-", "-", "-", "-"])
	print("\n--- done ---")
	quit(0)


func _measure(label: String, kind: String, blend: float, depth: int) -> void:
	var wins := 0
	var decisions := 0
	# Calls that actually reached a model. Zero on a row that names one means
	# every game was the fallback agent in disguise — which has cost three runs
	# now, so it gets a column of its own.
	var net_calls := 0
	for i in range(games):
		var agent: BaseAgent
		match kind:
			"policysearch":
				var searcher := PolicySearchAgent.new(0)
				searcher.search_depth = depth
				agent = searcher
			"policy":
				agent = PolicyAgent.new(0)
			"valuenet":
				var net := ValueNetAgent.new(0)
				net.blend = blend
				net.search_depth = depth
				agent = net
			_:
				agent = GreedyAgent.new(0)
		var session := GameSession.new()
		session.max_actions = 3000
		# Same seeds and the same seat alternation for every setting.
		session.setup(DECK, DECK, agent, GreedyAgent.new(1), 900 + i, i % 2)
		var final_state := session.run_sync()
		decisions += session.actions_taken
		if agent is PolicyAgent:
			net_calls += (agent as PolicyAgent).decisions
		elif agent is ValueNetAgent:
			net_calls += (agent as ValueNetAgent).requests_made
		if final_state.winner_id == 0:
			wins += 1
		var died := (agent is ValueNetAgent and (agent as ValueNetAgent).offline) \
			or (agent is PolicyAgent and (agent as PolicyAgent).offline)
		if died:
			print("  [!] server stopped answering — these games are the fallback, not the model")
	var note := ""
	if kind != "greedy" and net_calls == 0:
		note = "   <- FALLBACK, not the model"
	print("%-16s %8d %7.1f%% %10d %10d%s" % [
		label, wins, 100.0 * wins / games, decisions / games, net_calls / games, note,
	])
