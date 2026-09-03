class_name MatchRunner
extends RefCounted

## Headless AI-vs-AI self-play. Used by the Training screen and the unit tests.
## Individual games run through GameSession, so they follow exactly the same
## rules and action set as an interactive game.


static func play_game(
	agent0: BaseAgent,
	agent1: BaseAgent,
	deck0_path: String,
	deck1_path: String,
	max_actions: int = 3000,
	recorder: GameRecorder = null,
	rng_seed: int = 0
) -> MTGGameState:
	var session := GameSession.new()
	session.max_actions = max_actions
	session.setup(deck0_path, deck1_path, agent0, agent1, rng_seed)
	if recorder:
		recorder.attach(session)
	return session.run_sync()


static func new_results() -> Dictionary:
	return {"games": 0, "wins_p0": 0, "wins_p1": 0, "draws": 0, "total_turns": 0}


static func record_result(results: Dictionary, final_state: MTGGameState) -> void:
	results["games"] += 1
	results["total_turns"] += final_state.turn_number
	match final_state.winner_id:
		0:
			results["wins_p0"] += 1
		1:
			results["wins_p1"] += 1
		_:
			results["draws"] += 1


static func summary_text(results: Dictionary, name0: String, name1: String) -> String:
	var games: int = max(results["games"], 1)
	return "%s wins: %d (%.1f%%)\n%s wins: %d (%.1f%%)\nDraws: %d\nAverage turns per game: %.1f" % [
		name0, results["wins_p0"], 100.0 * results["wins_p0"] / games,
		name1, results["wins_p1"], 100.0 * results["wins_p1"] / games,
		results["draws"],
		float(results["total_turns"]) / games
	]


## Runs a whole series and prints a report. Returns the results dictionary.
static func run_match_simulation(
	agent0: BaseAgent,
	agent1: BaseAgent,
	deck0_path: String,
	deck1_path: String,
	total_games: int = 10,
	max_actions_per_game: int = 3000
) -> Dictionary:
	print("\n=== AI self-play: %d game(s) ===" % total_games)
	print(" P0: %s | %s" % [agent0.agent_name, deck0_path])
	print(" P1: %s | %s" % [agent1.agent_name, deck1_path])

	var results := new_results()
	for game_idx in range(total_games):
		var final_state := play_game(agent0, agent1, deck0_path, deck1_path, max_actions_per_game)
		record_result(results, final_state)
		var winner := "draw"
		if final_state.winner_id == 0:
			winner = agent0.agent_name
		elif final_state.winner_id == 1:
			winner = agent1.agent_name
		print(" Game %d/%d: %d turns — %s" % [game_idx + 1, total_games, final_state.turn_number, winner])

	print(summary_text(results, agent0.agent_name, agent1.agent_name))
	print("================================\n")
	return results
