extends SceneTree

## How strong is each agent, in win rate? This is where every number on the
## AI Stats screen and in ai/HANDOFF.md comes from.
##
##   cd ai/python && python -m mtgai.serve \
##       --policy-checkpoint checkpoints/policy_net.pt \
##       --checkpoint checkpoints/B/value_net.pt
##   godot --headless -s tests/sweep_blend.gd -- 100
##
## Measured rows are written back into res://data/ai_stats.json, so the screen
## and the docs cannot drift from the last real measurement. Rows that fell back
## to Greedy are not written: a rate under a model's name that the model never
## produced is worse than no number at all.
##
## Every setting plays the same seeds against GreedyAgent, with the seats
## alternated, so the rows are comparable to each other and not just to 50%.
##
## The `greedy` row is the control: GreedyAgent against itself, which must land
## near 50%. Anything else means the seeds or the seat alternation are unfair,
## and no other row on that run means anything.
##
## The `net calls` column is the second control. A row that names a model and
## shows zero is the Greedy fallback wearing the model's name — which has cost
## three runs so far, and is why it gets a column instead of a footnote.

const DECK := "res://data/decks/botboys_deck_izzet.txt"
const STATS_PATH := "res://data/ai_stats.json"

## Sweep row label -> [agent id, result label] in data/ai_stats.json. A row
## missing from here is printed but not stored.
const STATS_ROWS := {
	"greedy": ["greedy", "self-play control"],
	"value 1-ply": ["valuenet", "1 ply"],
	"value 2-ply": ["valuenet", "2 ply"],
	"value mix 2-ply": ["valuenet", "mixed with formula"],
	"policy": ["policy", "single pass"],
	"policy+search 1": ["policysearch", "depth 1"],
	"policy+search 2": ["policysearch", "depth 2"],
}
## Default is a smoke test. Eight games means a standard error of +/-18% on a
## win rate, which cannot tell 45% from 60% — pass a real number for a real
## measurement:  godot --headless -s tests/sweep_blend.gd -- 100
const DEFAULT_GAMES := 8

var games := DEFAULT_GAMES
## Rows that actually measured what they claim to, for data/ai_stats.json.
var _rows: Array[Dictionary] = []


func _init() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0 and argv[0].is_valid_int():
		games = argv[0].to_int()
	print("--- strength sweep: %d games per setting, opponent is Greedy ---" % games)
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
	_write_stats()
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
	if note.is_empty():
		_rows.append({"label": label, "win_rate": float(wins) / games})


## Folds the measured rows into data/ai_stats.json, leaving the hand-written
## prose and any row this sweep did not measure exactly as they were.
func _write_stats() -> void:
	if _rows.is_empty():
		return
	var stats := _read_stats()
	if stats.is_empty():
		print("  [!] %s is missing or unreadable — nothing written" % STATS_PATH)
		return

	var today := Time.get_datetime_string_from_system(true).substr(0, 10)
	var measured: Dictionary = stats.get("measured", {})
	measured["date"] = today
	measured["games"] = games
	measured["opponent"] = "Greedy AI (1-ply search)"
	measured["harness"] = "tests/sweep_blend.gd -- %d" % games
	measured["standard_error"] = snappedf(0.5 / sqrt(float(games)), 0.001)
	stats["measured"] = measured

	var written := 0
	for row in _rows:
		var mapping: Variant = STATS_ROWS.get(row["label"])
		if mapping == null:
			continue
		var results: Variant = _results_for(stats, str(mapping[0]))
		if results == null:
			print("  [!] no agent '%s' in %s — skipped" % [mapping[0], STATS_PATH])
			continue
		var entry: Dictionary = _result_row(results, str(mapping[1]))
		entry["win_rate"] = snappedf(row["win_rate"], 0.001)
		entry["games"] = games
		entry["date"] = today
		entry.erase("estimate")
		written += 1

	_integerise_counts(stats)

	var file := FileAccess.open(STATS_PATH, FileAccess.WRITE)
	if file == null:
		print("  [!] could not write %s (%s) — the AI Stats screen keeps its old numbers" % [
			STATS_PATH, error_string(FileAccess.get_open_error()),
		])
		return
	file.store_string(JSON.stringify(stats, "  ", false) + "\n")
	file.close()
	print("  %d row(s) written to %s" % [written, STATS_PATH])


func _read_stats() -> Dictionary:
	if not FileAccess.file_exists(STATS_PATH):
		return {}
	var file := FileAccess.open(STATS_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


## The results array of one agent, or null if the file does not list it. The
## array is the one inside `stats`, so writing through it updates the file.
func _results_for(stats: Dictionary, agent_id: String) -> Variant:
	var agents: Variant = stats.get("agents", [])
	if not (agents is Array):
		return null
	for entry in agents as Array:
		if not (entry is Dictionary) or str((entry as Dictionary).get("id", "")) != agent_id:
			continue
		var agent := entry as Dictionary
		if not (agent.get("results") is Array):
			agent["results"] = []
		return agent["results"]
	return null


## The row with this label, appended if the file does not have it yet. Appending
## rather than replacing keeps the first row as the headline the screen shows.
func _result_row(results: Variant, label: String) -> Dictionary:
	for row in results as Array:
		if row is Dictionary and str((row as Dictionary).get("label", "")) == label:
			return row as Dictionary
	var fresh := {"label": label}
	(results as Array).append(fresh)
	return fresh


## JSON has one number type, so every count came back from the parser as a
## float. Left alone, a row nobody measured is rewritten as "games": 100.0.
func _integerise_counts(stats: Dictionary) -> void:
	var agents: Variant = stats.get("agents", [])
	if not (agents is Array):
		return
	for entry in agents as Array:
		if not (entry is Dictionary):
			continue
		var results: Variant = (entry as Dictionary).get("results", [])
		if not (results is Array):
			continue
		for row in results as Array:
			if row is Dictionary and (row as Dictionary).get("games") != null:
				(row as Dictionary)["games"] = int((row as Dictionary)["games"])
