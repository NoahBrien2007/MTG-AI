extends Node

## Autoload "GameConfig": carries the choices made in the menus into the game
## scene and knows how to build agents / find decks.

const SCENE_MAIN_MENU := "res://scenes/MainMenu.tscn"
const SCENE_DECK_SELECT := "res://scenes/DeckSelect.tscn"
const SCENE_TRAINING := "res://scenes/Training.tscn"
const SCENE_AI_STATS := "res://scenes/AIStats.tscn"
const SCENE_GAME := "res://scenes/Game.tscn"

const DECK_DIR := "res://data/decks"

## id -> display name
const AGENT_TYPES := {
	"heuristic": "Heuristic AI",
	"greedy": "Greedy AI (1-ply search)",
	"valuenet": "Value Net AI (needs mtgai.serve)",
	"policy": "Policy AI (needs mtgai.serve --policy-checkpoint)",
	"policysearch": "Policy + Search AI (needs mtgai.serve --policy-checkpoint)",
	"random": "Random AI",
}

var player_deck_path: String = GameSession.DEFAULT_DECK
var opponent_deck_path: String = GameSession.DEFAULT_DECK
var opponent_agent: String = "heuristic"


func create_agent(kind: String, player_id: int) -> BaseAgent:
	match kind:
		"greedy":
			return GreedyAgent.new(player_id)
		"valuenet":
			return ValueNetAgent.new(player_id)
		"policy":
			return PolicyAgent.new(player_id)
		"policysearch":
			return PolicySearchAgent.new(player_id)
		"random":
			return RandomAgent.new(player_id)
		_:
			return HeuristicAgent.new(player_id)


## All deck lists (*.txt) in the deck folder, as res:// paths.
func list_deck_files() -> PackedStringArray:
	var decks: PackedStringArray = []
	var dir := DirAccess.open(DECK_DIR)
	if dir == null:
		push_warning("GameConfig: deck folder not found: " + DECK_DIR)
		return decks
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "txt":
			decks.append(DECK_DIR + "/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	decks.sort()
	return decks


## Uses the first comment line of the deck file as its name, else the file name.
func deck_display_name(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		while not file.eof_reached():
			var line := file.get_line().strip_edges()
			if line.begins_with("//") or line.begins_with("#"):
				var title := line.trim_prefix("//").trim_prefix("#").strip_edges()
				if not title.is_empty():
					return title
			elif not line.is_empty():
				break
	return path.get_file().get_basename().capitalize()


func go_to(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)
