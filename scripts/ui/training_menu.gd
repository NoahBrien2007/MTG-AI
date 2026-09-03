extends Control

## AI Training screen: configures and runs headless self-play series.
## Games run one per frame so the UI stays responsive and progress is visible.

@onready var agent_a: OptionButton = $Margin/VBox/Grid/AgentA
@onready var agent_b: OptionButton = $Margin/VBox/Grid/AgentB
@onready var deck_a: OptionButton = $Margin/VBox/Grid/DeckA
@onready var deck_b: OptionButton = $Margin/VBox/Grid/DeckB
@onready var games_spin: SpinBox = $Margin/VBox/Grid/Games
@onready var chk_record: CheckBox = $Margin/VBox/Grid/Record
@onready var progress: ProgressBar = $Margin/VBox/Progress
@onready var results_label: RichTextLabel = $Margin/VBox/Results
@onready var btn_back: Button = $Margin/VBox/Buttons/BtnBack
@onready var btn_run: Button = $Margin/VBox/Buttons/BtnRun

var _deck_paths: PackedStringArray = []
var _running: bool = false
var _cancel: bool = false


func _ready() -> void:
	_deck_paths = GameConfig.list_deck_files()
	for path in _deck_paths:
		var label := GameConfig.deck_display_name(path)
		deck_a.add_item(label)
		deck_b.add_item(label)

	var agent_ids := GameConfig.AGENT_TYPES.keys()
	for i in range(agent_ids.size()):
		for option in [agent_a, agent_b]:
			option.add_item(GameConfig.AGENT_TYPES[agent_ids[i]], i)
			option.set_item_metadata(i, agent_ids[i])
	if agent_ids.size() > 1:
		agent_b.select(1)

	btn_back.pressed.connect(_on_back_pressed)
	btn_run.pressed.connect(_on_run_pressed)
	btn_run.disabled = _deck_paths.is_empty()
	if _deck_paths.is_empty():
		results_label.text = "No deck lists found in %s" % GameConfig.DECK_DIR


func _on_back_pressed() -> void:
	if _running:
		_cancel = true
		return
	GameConfig.go_to(GameConfig.SCENE_MAIN_MENU)


func _on_run_pressed() -> void:
	if _running:
		_cancel = true
		return
	_run_series()


func _run_series() -> void:
	_running = true
	_cancel = false
	btn_run.text = "Stop"
	btn_back.text = "Stop"

	var kind_a: String = agent_a.get_item_metadata(agent_a.selected)
	var kind_b: String = agent_b.get_item_metadata(agent_b.selected)
	var path_a: String = _deck_paths[deck_a.selected]
	var path_b: String = _deck_paths[deck_b.selected]
	var total := int(games_spin.value)

	var name_a: String = GameConfig.AGENT_TYPES[kind_a]
	var name_b: String = GameConfig.AGENT_TYPES[kind_b]

	results_label.clear()
	results_label.append_text("[b]%s[/b] vs [b]%s[/b] — %d game(s)\n" % [name_a, name_b, total])
	progress.max_value = total
	progress.value = 0

	results_label.append_text("Loading card database…\n")
	await get_tree().process_frame
	CardDatabase.load_cards_from_csv()

	# Probe the value net once up front. Without this a stopped server just
	# means every ValueNetAgent silently falls back, and the series measures
	# Greedy against Greedy while claiming to measure the model.
	# PolicySearchAgent extends PolicyAgent, so it needs the same server and was
	# silently skipping this gate — which matters most for the self-play crank,
	# where a stopped server means 1000 games of Greedy recorded under the
	# policy's name.
	const POLICY_KINDS := ["policy", "policysearch"]
	if kind_a in POLICY_KINDS or kind_b in POLICY_KINDS:
		var policy_health := PolicyAgent.new(0).health_check()
		if not policy_health.get("ok", false):
			results_label.append_text("[color=#ff8080]%s[/color]\n" % policy_health.get("error", "policy unavailable"))
			results_label.append_text("Start it with: [code]cd ai/python && python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt[/code]\n")
			_running = false
			btn_run.text = "Run"
			btn_back.text = "Back"
			return
		results_label.append_text("Policy ready — %d features, %d cards.\n" % [
			policy_health["feature_count"], policy_health["vocab_size"],
		])

	if kind_a == "valuenet" or kind_b == "valuenet":
		var health := ValueNetAgent.new(0).health_check()
		if not health.get("ok", false):
			results_label.append_text("[color=#ff8080]%s[/color]\n" % health.get("error", "value net unavailable"))
			results_label.append_text("Start it with: [code]cd ai/python && python -m mtgai.serve[/code]\n")
			_running = false
			btn_run.text = "Run"
			btn_back.text = "Back"
			return
		results_label.append_text("Value net ready — %d features, %d cards.\n" % [
			health["feature_count"], health["vocab_size"],
		])

	var recorder: GameRecorder = GameRecorder.new() if chk_record.button_pressed else null
	if recorder:
		# Stream each game to disk as it finishes. Buffering a long series in
		# memory needs gigabytes and dies well before the last game.
		var folder := recorder.begin_stream()
		if folder.is_empty():
			results_label.append_text("[color=#ff8080]Could not open the dataset folder — this run is NOT being recorded.[/color]\n")
			recorder = null
		else:
			results_label.append_text("Recording to %s\n" % folder)
	var results := MatchRunner.new_results()
	var started := Time.get_ticks_msec()
	for i in range(total):
		if _cancel:
			results_label.append_text("[color=orange]Stopped after %d game(s).[/color]\n" % i)
			break
		var a := GameConfig.create_agent(kind_a, 0)
		var b := GameConfig.create_agent(kind_b, 1)
		# Alternate who is on the play, otherwise seat 0 keeps the first-player
		# advantage in every game and both the results and the recorded data are biased.
		var final_state := MatchRunner.play_game(a, b, path_a, path_b, 3000, recorder, 0, i % 2)
		MatchRunner.record_result(results, final_state)

		var winner := "draw"
		if final_state.winner_id == 0:
			winner = name_a
		elif final_state.winner_id == 1:
			winner = name_b
		var on_play := name_a if final_state.starting_player == 0 else name_b
		results_label.append_text("Game %d: %d turns — %s won (%s on the play)\n" % [
			i + 1, final_state.turn_number, winner, on_play,
		])
		progress.value = i + 1
		await get_tree().process_frame

	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	results_label.append_text("\n[b]Results[/b] (%.1f s)\n%s\n" % [seconds, MatchRunner.summary_text(results, name_a, name_b)])
	print(MatchRunner.summary_text(results, name_a, name_b))
	if recorder and recorder.games_recorded > 0:
		var path := recorder.save()
		results_label.append_text("[color=#9fd3ff]Training data: %d games, %d decisions in %d file(s) under %s[/color]\n" % [
			recorder.games_recorded, recorder.decisions_recorded, recorder.written_files.size(), path,
		])
		print("Training data written to %s" % path)

	_running = false
	btn_run.text = "Run"
	btn_back.text = "Back"
