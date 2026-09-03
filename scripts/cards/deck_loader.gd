class_name DeckLoader
extends RefCounted

## Reads a plain-text deck list ("4 Opt", "// comment") into CardInstances.


## Card names and counts in a deck file: Array of {"name": String, "count": int}.
static func read_deck_list(file_path: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var full_path := file_path
	if not FileAccess.file_exists(full_path):
		full_path = "res://" + file_path
		if not FileAccess.file_exists(full_path):
			push_warning("DeckLoader: deck file not found: " + file_path)
			return entries

	var file := FileAccess.open(full_path, FileAccess.READ)
	if not file:
		return entries
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("//") or line.begins_with("#"):
			continue
		var parts := line.split(" ", false, 1)
		if parts.size() < 2 or not parts[0].is_valid_int() or parts[0].to_int() <= 0:
			continue
		entries.append({"name": parts[1].strip_edges(), "count": parts[0].to_int()})
	return entries


static func load_deck_from_file(file_path: String, player_id: int, state: MTGGameState) -> Array[CardInstance]:
	var deck: Array[CardInstance] = []
	var entries := read_deck_list(file_path)

	# One database lookup pass for the whole deck (at most one CSV scan).
	var names: PackedStringArray = []
	for entry in entries:
		names.append(entry["name"])
	CardDatabase.preload_names(names)

	for entry in entries:
		var def := CardDatabase.get_card_definition(entry["name"])
		for i in range(int(entry["count"])):
			deck.append(CardInstance.new(state.next_instance_id, def, player_id))
			state.next_instance_id += 1
	return deck
