extends Control

## Deck selection screen shown before a game.

@onready var player_decks: ItemList = $Margin/VBox/Columns/PlayerCol/PlayerDecks
@onready var opponent_decks: ItemList = $Margin/VBox/Columns/OpponentCol/OpponentDecks
@onready var agent_option: OptionButton = $Margin/VBox/Columns/OpponentCol/AgentOption
@onready var preview: RichTextLabel = $Margin/VBox/Preview
@onready var lbl_status: Label = $Margin/VBox/Buttons/LblStatus
@onready var btn_back: Button = $Margin/VBox/Buttons/BtnBack
@onready var btn_start: Button = $Margin/VBox/Buttons/BtnStart

var _deck_paths: PackedStringArray = []


func _ready() -> void:
	_deck_paths = GameConfig.list_deck_files()
	for path in _deck_paths:
		var label := GameConfig.deck_display_name(path)
		player_decks.add_item(label)
		opponent_decks.add_item(label)

	var agent_ids := GameConfig.AGENT_TYPES.keys()
	for i in range(agent_ids.size()):
		agent_option.add_item(GameConfig.AGENT_TYPES[agent_ids[i]], i)
		agent_option.set_item_metadata(i, agent_ids[i])
		if agent_ids[i] == GameConfig.opponent_agent:
			agent_option.select(i)

	_select_path(player_decks, GameConfig.player_deck_path)
	_select_path(opponent_decks, GameConfig.opponent_deck_path)

	player_decks.item_selected.connect(_on_player_deck_selected)
	opponent_decks.item_selected.connect(func(_idx: int) -> void: _update_start_button())
	btn_back.pressed.connect(func() -> void: GameConfig.go_to(GameConfig.SCENE_MAIN_MENU))
	btn_start.pressed.connect(_on_start_pressed)

	if _deck_paths.is_empty():
		lbl_status.text = "No deck lists (*.txt) found in %s" % GameConfig.DECK_DIR
	_update_start_button()
	if player_decks.is_anything_selected():
		_show_preview(_deck_paths[player_decks.get_selected_items()[0]])


func _select_path(list: ItemList, path: String) -> void:
	var idx := _deck_paths.find(path)
	if idx == -1 and not _deck_paths.is_empty():
		idx = 0
	if idx != -1:
		list.select(idx)


func _on_player_deck_selected(idx: int) -> void:
	_show_preview(_deck_paths[idx])
	_update_start_button()


func _show_preview(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		preview.text = "Could not open deck file."
		return
	var lines: PackedStringArray = []
	var total := 0
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("//") or line.begins_with("#"):
			lines.append("[color=#8fa3bf]%s[/color]" % line.trim_prefix("//").trim_prefix("#").strip_edges())
			continue
		var parts := line.split(" ", false, 1)
		if parts.size() == 2 and parts[0].is_valid_int():
			total += parts[0].to_int()
		lines.append(line)
	preview.text = "[b]%d cards[/b]\n%s" % [total, "\n".join(lines)]


func _update_start_button() -> void:
	btn_start.disabled = not (player_decks.is_anything_selected() and opponent_decks.is_anything_selected())


func _on_start_pressed() -> void:
	GameConfig.player_deck_path = _deck_paths[player_decks.get_selected_items()[0]]
	GameConfig.opponent_deck_path = _deck_paths[opponent_decks.get_selected_items()[0]]
	GameConfig.opponent_agent = agent_option.get_item_metadata(agent_option.selected)

	# The card database is parsed from cards.csv on first use, which can take a moment.
	lbl_status.text = "Loading cards…"
	btn_start.disabled = true
	await get_tree().process_frame
	CardDatabase.load_cards_from_csv()
	GameConfig.go_to(GameConfig.SCENE_GAME)
