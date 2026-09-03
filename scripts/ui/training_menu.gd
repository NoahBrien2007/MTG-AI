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

	var recorder: GameRecorder = GameRecorder.new() if chk_record.button_pressed else null
	var results := MatchRunner.new_results()
	var started := Time.get_ticks_msec()
	for i in range(total):
		if _cancel:
			results_label.append_text("[color=orange]Stopped after %d game(s).[/color]\n" % i)
			break
		var a := GameConfig.create_agent(kind_a, 0)
		var b := GameConfig.create_agent(kind_b, 1)
		var final_state := MatchRunner.play_game(a, b, path_a, path_b, 3000, recorder)
		MatchRunner.record_result(results, final_state)

		var winner := "draw"
		if final_state.winner_id == 0:
			winner = name_a
		elif final_state.winner_id == 1:
			winner = name_b
		results_label.append_text("Game %d: %d turns — %s\n" % [i + 1, final_state.turn_number, winner])
		progress.value = i + 1
		await get_tree().process_frame

	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	results_label.append_text("\n[b]Results[/b] (%.1f s)\n%s\n" % [seconds, MatchRunner.summary_text(results, name_a, name_b)])
	print(MatchRunner.summary_text(results, name_a, name_b))
	if recorder and recorder.games_recorded > 0:
		var path := recorder.save()
		results_label.append_text("[color=#9fd3ff]Training data (%d games) saved to %s[/color]\n" % [recorder.games_recorded, path])

	_running = false
	btn_run.text = "Run"
	btn_back.text = "Back"
