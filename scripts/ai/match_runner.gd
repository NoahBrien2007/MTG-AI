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
	rng_seed: int = 0,
	first_player: int = 0
) -> MTGGameState:
	var session := GameSession.new()
	session.max_actions = max_actions
	session.setup(deck0_path, deck1_path, agent0, agent1, rng_seed, first_player)
	if recorder:
		recorder.attach(session)
	return session.run_sync()


static func new_results() -> Dictionary:
	return {
		"games": 0, "wins_p0": 0, "wins_p1": 0, "draws": 0, "total_turns": 0,
		# Split by who was on the play, to separate agent strength from the
		# first-player advantage.
		"games_on_play": 0, "wins_on_play": 0,
	}


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

	results["games_on_play"] += 1
	if final_state.winner_id == final_state.starting_player:
		results["wins_on_play"] += 1


static func summary_text(results: Dictionary, name0: String, name1: String) -> String:
	var games: int = max(results["games"], 1)
	var lines := "%s wins: %d (%.1f%%)\n%s wins: %d (%.1f%%)\nDraws: %d\nAverage turns per game: %.1f" % [
		name0, results["wins_p0"], 100.0 * results["wins_p0"] / games,
		name1, results["wins_p1"], 100.0 * results["wins_p1"] / games,
		results["draws"],
		float(results["total_turns"]) / games
	]

	var on_play_games: int = results.get("games_on_play", 0)
	if on_play_games > 0:
		lines += "\nWon while on the play: %.1f%%" % (100.0 * results["wins_on_play"] / on_play_games)

	# A lopsided result is nearly always a bug, not a skill gap: a paralysed
	# agent, or one seat keeping the first-player advantage every game.
	var top: int = max(results["wins_p0"], results["wins_p1"])
	if games >= 20 and float(top) / games >= 0.95:
		lines += "\n[!] One agent won %.0f%% of games — check for a broken agent " % (100.0 * top / games)
		lines += "before training on this data."
	return lines


## Runs a whole series and prints a report. Returns the results dictionary.
static func run_match_simulation(
	agent0: BaseAgent,
	agent1: BaseAgent,
	deck0_path: String,
	deck1_path: String,
	total_games: int = 10,
	max_actions_per_game: int = 3000,
	alternate_play: bool = true
) -> Dictionary:
	print("\n=== AI self-play: %d game(s) ===" % total_games)
	print(" P0: %s | %s" % [agent0.agent_name, deck0_path])
	print(" P1: %s | %s" % [agent1.agent_name, deck1_path])

	var results := new_results()
	for game_idx in range(total_games):
		var first_player := (game_idx % 2) if alternate_play else 0
		var final_state := play_game(
			agent0, agent1, deck0_path, deck1_path, max_actions_per_game, null, 0, first_player
		)
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
