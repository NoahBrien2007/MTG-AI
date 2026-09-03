class_name GameRecorder
extends RefCounted

## Records every decision of a game as training data.
##
## Attach to a GameSession with `attach(session)`. Each decision becomes one
## sample: the encoded state from the acting player's view, the encoded legal
## actions, the index of the chosen one and (filled in at game end) the outcome
## for that player (+1 win, -1 loss, 0 draw).
##
## Output goes into the project, under ai/training/datasets/ — the same folder
## the Python trainer reads by default (see ai/python/mtgai/paths.py), so
## recordings never end up in the OS user-data directory. Only an exported
## build, whose res:// is read-only, falls back to user://training/datasets/.
##
## Two ways to write:
##   * `save()` alone — everything is buffered in memory and written at the end.
##     Fine for a handful of games (the unit tests use it).
##   * `begin_stream()` before the series, `save()` after — each game is appended
##     to disk as it finishes and dropped from memory. Use this for long series:
##     one game is ~300 decisions and a decision carries ~1100 floats, so a
##     thousand games buffered in RAM runs into gigabytes and dies long before
##     the series ends.

const PROJECT_OUTPUT_DIR := "res://ai/training/datasets/"
const FALLBACK_OUTPUT_DIR := "user://training/datasets/"

## Games per file while streaming. Sharding keeps a long run from producing one
## multi-gigabyte blob; the trainer reads the whole folder, so it makes no
## difference to it whether a run is one file or ten.
const GAMES_PER_FILE := 250

var samples: Array[Dictionary] = []
var games_recorded: int = 0
## Total decisions seen, whether or not they are still in `samples`.
var decisions_recorded: int = 0
## Absolute paths of the files written so far (streaming mode).
var written_files: PackedStringArray = []

var _session: GameSession
var _current: Array[Dictionary] = []
var _streaming := false
var _stream: FileAccess = null
var _stream_dir := ""
var _stream_stem := ""
var _stream_games := 0
var _shard := 0


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
		# The trainer splits train/validation by game so decisions from one game
		# never land on both sides — without this id every sample looks like the
		# same game and the split collapses (see ai/python/mtgai/data.py).
		sample["game"] = games_recorded
	decisions_recorded += _current.size()
	games_recorded += 1
	if _stream != null:
		_write_game()
	else:
		samples.append_array(_current)
	_current = []


# ───────────────────────────── Output ─────────────────────────────

## Where recordings are written. Running from source — the editor, or
## `godot --headless -s` with the editor binary — writes into the project;
## only an exported build, whose res:// is read-only, falls back to user://.
static func output_dir() -> String:
	return FALLBACK_OUTPUT_DIR if OS.has_feature("template") else PROJECT_OUTPUT_DIR


static func _timestamp_stem() -> String:
	return "games_%s" % Time.get_datetime_string_from_system().replace(":", "-")


func _header(games_in_file: int) -> Dictionary:
	return {
		"format": "mtg-ai-samples-v1",
		"feature_count": StateEncoder.feature_count(),
		"card_features": StateEncoder.CARD_FEATURES,
		"action_features": StateEncoder.ACTION_FEATURES,
		"vocabulary": Array(StateEncoder.vocabulary()),
		# -1 while a streamed file is still open; the reader counts games from
		# the per-sample "game" field anyway.
		"games": games_in_file,
	}


## Starts writing games to disk as they finish. Returns the folder recordings
## go to, or "" if it could not be opened.
func begin_stream(stem: String = "") -> String:
	_streaming = true
	_stream_dir = output_dir()
	DirAccess.make_dir_recursive_absolute(_stream_dir)
	_stream_stem = stem if not stem.is_empty() else _timestamp_stem()
	_shard = 0
	if not _open_shard():
		return ""
	return ProjectSettings.globalize_path(_stream_dir)


func _open_shard() -> bool:
	var suffix := "" if _shard == 0 else "_part%d" % (_shard + 1)
	var path := "%s%s%s.jsonl" % [_stream_dir, _stream_stem, suffix]
	_stream = FileAccess.open(path, FileAccess.WRITE)
	if _stream == null:
		push_warning("GameRecorder: cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	_stream.store_line(JSON.stringify(_header(-1)))
	_stream_games = 0
	written_files.append(ProjectSettings.globalize_path(path))
	return true


func _write_game() -> void:
	# Rotate lazily — only when there is a game to put in the next shard, so a
	# run that ends exactly on a shard boundary leaves no empty trailing file.
	if _stream_games >= GAMES_PER_FILE:
		_stream.close()
		_shard += 1
		if not _open_shard():
			_stream = null
			return
	for sample in _current:
		_stream.store_line(JSON.stringify(sample))
	# Flushed per game so a crash or a cancelled series keeps everything up to
	# the last completed game.
	_stream.flush()
	_stream_games += 1


## Finishes the recording and clears the buffer. Returns the path written: the
## dataset folder when streaming (a long run is several files), otherwise the
## single .jsonl file.
func save(file_name: String = "") -> String:
	if _streaming:
		if _stream != null:
			_stream.close()
			_stream = null
		return ProjectSettings.globalize_path(_stream_dir)

	var dir := output_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	if file_name.is_empty():
		file_name = _timestamp_stem() + ".jsonl"
	var path := dir + file_name
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("GameRecorder: cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return ""
	file.store_line(JSON.stringify(_header(games_recorded)))
	for sample in samples:
		file.store_line(JSON.stringify(sample))
	file.close()
	samples.clear()
	written_files.append(ProjectSettings.globalize_path(path))
	return ProjectSettings.globalize_path(path)
