class_name GameRecorder
extends RefCounted

## Records every decision of a game as training data.
##
## Attach to a GameSession with `attach(session)`. Each decision becomes one
## sample: the encoded state from the acting player's view, the encoded legal
## actions, the index of the chosen one and (filled in at game end) the outcome
## for that player (+1 win, -1 loss, 0 draw). `save()` appends one JSON object
## per game to a .jsonl file under user://training/ — the format is meant to be
## read by a Python training script.

const OUTPUT_DIR := "user://training/"

var samples: Array[Dictionary] = []
var games_recorded: int = 0
var _session: GameSession
var _current: Array[Dictionary] = []


func attach(session: GameSession) -> void:
	_session = session
	session.decision_made.connect(_on_decision)
	session.finished.connect(_on_finished)


func _on_decision(state: MTGGameState, legal: Array[MTGAction], chosen: int) -> void:
	var player := state.acting_player()
	var encoded := StateEncoder.encode(state, player)
	var actions: Array = []
	var signatures: PackedStringArray = []
	for action in legal:
		actions.append(Array(StateEncoder.encode_action(action, state, player)))
		signatures.append(action.signature())
	_current.append({
		"player": player,
		"turn": state.turn_number,
		"features": Array(encoded["features"]),
		"card_ids": Array(encoded["card_ids"]),
		"legal": actions,
		"legal_signatures": signatures,
		"chosen": chosen,
	})


func _on_finished(state: MTGGameState) -> void:
	for sample in _current:
		var p: int = sample["player"]
		sample["outcome"] = 0 if state.winner_id == -1 else (1 if state.winner_id == p else -1)
	samples.append_array(_current)
	_current = []
	games_recorded += 1


## Writes the recorded games and clears the buffer. Returns the file path.
func save(file_name: String = "") -> String:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	if file_name.is_empty():
		file_name = "games_%s.jsonl" % Time.get_datetime_string_from_system().replace(":", "-")
	var path := OUTPUT_DIR + file_name
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("GameRecorder: cannot write %s" % path)
		return ""
	file.store_line(JSON.stringify({
		"format": "mtg-ai-samples-v1",
		"feature_count": StateEncoder.feature_count(),
		"card_features": StateEncoder.CARD_FEATURES,
		"vocabulary": Array(StateEncoder.vocabulary()),
		"games": games_recorded,
	}))
	for sample in samples:
		file.store_line(JSON.stringify(sample))
	file.close()
	samples.clear()
	return ProjectSettings.globalize_path(path)
