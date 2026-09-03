extends Control

## AI Stats: what each agent is, what it needs, and how strong it actually is.
##
## Every number comes from res://data/ai_stats.json, which tests/sweep_blend.gd
## rewrites after a run — so this screen cannot quietly disagree with the last
## measurement. The prose (summary, capabilities, limits) is hand-written in the
## same file; the sweep only touches the results blocks.
##
## The status beside each agent is live, from one /health probe. That matters
## more than it sounds: a network agent whose server is down plays as Greedy and
## still reports a win rate, which has cost this project three wasted runs. An
## agent that cannot run right now says so here, next to its number.

const STATS_PATH := "res://data/ai_stats.json"

const COL_PANEL := Color(0.11, 0.12, 0.16)
const COL_DIM := Color(1, 1, 1, 0.55)
const COL_READY := Color(0.45, 0.85, 0.5)
const COL_WAITING := Color(1.0, 0.72, 0.32)
const COL_BROKEN := Color(1.0, 0.5, 0.5)
const COL_BASELINE := Color(0.62, 0.78, 1.0)

@onready var subtitle: Label = $Margin/VBox/Subtitle
@onready var server_line: RichTextLabel = $Margin/VBox/ServerLine
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var btn_back: Button = $Margin/VBox/Buttons/BtnBack
@onready var btn_refresh: Button = $Margin/VBox/Buttons/BtnRefresh

var _stats: Dictionary = {}
## The parsed /health body, or empty if nothing is listening.
var _health: Dictionary = {}
## Greedy's own win rate: the control every other row is read against.
var _baseline: float = 0.0


func _ready() -> void:
	btn_back.pressed.connect(func() -> void: GameConfig.go_to(GameConfig.SCENE_MAIN_MENU))
	btn_refresh.pressed.connect(_refresh)
	_reload()
	# Paint from the file first, then block on the socket. The probe is a
	# blocking connect, and a screen that appears blank while it runs looks
	# broken even when it takes 20 ms.
	_render()
	await get_tree().process_frame
	_probe()
	_render()
	btn_back.grab_focus()


func _refresh() -> void:
	btn_refresh.disabled = true
	_reload()
	await get_tree().process_frame
	_probe()
	_render()
	btn_refresh.disabled = false


func _reload() -> void:
	_stats = _load_stats()
	_baseline = _find_baseline()


func _load_stats() -> Dictionary:
	if not FileAccess.file_exists(STATS_PATH):
		push_warning("AIStats: %s is missing" % STATS_PATH)
		return {}
	var file := FileAccess.open(STATS_PATH, FileAccess.READ)
	if file == null:
		push_warning("AIStats: could not open %s" % STATS_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		push_warning("AIStats: %s is not a JSON object" % STATS_PATH)
		return {}
	return parsed as Dictionary


## One probe for the whole screen — every network agent shares the one server.
func _probe() -> void:
	var net := NetClient.new()
	var response: Variant = net.get_json("/health")
	if response is Dictionary and (response as Dictionary).get("ok", false):
		_health = response as Dictionary
	else:
		_health = {}


func _find_baseline() -> float:
	for entry in _agents():
		if entry is Dictionary and (entry as Dictionary).get("id", "") == "greedy":
			var rate: Variant = _headline(entry as Dictionary).get("win_rate")
			if rate != null:
				return float(rate)
	return 0.0


func _agents() -> Array:
	var agents: Variant = _stats.get("agents", [])
	if agents is Array:
		return agents as Array
	return []


## The first result block is the headline; the rest are variants of it.
func _headline(entry: Dictionary) -> Dictionary:
	var results: Variant = entry.get("results", [])
	if results is Array and not (results as Array).is_empty():
		var first: Variant = (results as Array)[0]
		if first is Dictionary:
			return first as Dictionary
	return {}


func _render() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()

	var measured: Dictionary = _stats.get("measured", {})
	if measured.is_empty():
		subtitle.text = "No measurements on file. Run: godot --headless -s tests/sweep_blend.gd -- 100"
	else:
		subtitle.text = "%d games against %s per row, standard error ±%.0f%% · measured %s" % [
			int(measured.get("games", 0)),
			str(measured.get("opponent", "Greedy")),
			100.0 * float(measured.get("standard_error", 0.0)),
			str(measured.get("date", "unknown")),
		]

	server_line.clear()
	if _health.is_empty():
		server_line.append_text("[color=#ffb852]Model server offline[/color] — network agents fall back to Greedy. ")
		server_line.append_text("Start it with [code]cd ai/python && python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt[/code]")
	else:
		var loaded: Array[String] = []
		if _health.get("policy", false):
			loaded.append("policy")
		if _health.get("value", false):
			loaded.append("value")
		var which := "no models"
		if not loaded.is_empty():
			which = ", ".join(loaded)
		server_line.append_text("[color=#73d97f]Model server up[/color] — %s loaded, %d features, %d cards in vocabulary." % [
			which, int(_health.get("feature_count", 0)), int(_health.get("vocab_size", 0)),
		])

	if _agents().is_empty():
		var empty := Label.new()
		empty.text = "Nothing to show — %s has no agents." % STATS_PATH
		empty.modulate = COL_DIM
		list.add_child(empty)
		return

	for entry in _agents():
		if entry is Dictionary:
			list.add_child(_build_card(entry as Dictionary))

	var note := str(measured.get("note", ""))
	if not note.is_empty():
		var footer := Label.new()
		footer.text = note
		footer.modulate = COL_DIM
		footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(footer)


func _build_card(entry: Dictionary) -> PanelContainer:
	var id := str(entry.get("id", ""))
	var display := _display_name(id)
	var headline := _headline(entry)
	var rate: Variant = headline.get("win_rate")

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _card_style())

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	# Header: name, live status, headline win rate.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	box.add_child(header)

	var name_label := Label.new()
	name_label.text = display
	name_label.add_theme_font_size_override("font_size", 22)
	header.add_child(name_label)

	var status := _status(str(entry.get("requires", "")))
	var status_label := Label.new()
	status_label.text = "· " + str(status["text"])
	status_label.modulate = status["color"]
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(status_label)

	var rate_label := Label.new()
	rate_label.add_theme_font_size_override("font_size", 22)
	if rate == null:
		rate_label.text = "—"
		rate_label.modulate = COL_DIM
	else:
		rate_label.text = "%.0f%%" % (100.0 * float(rate))
		rate_label.modulate = _rate_colour(id, float(rate))
	header.add_child(rate_label)

	box.add_child(_bar(id, rate))

	var against := ""
	if rate != null and id != "greedy" and _baseline > 0.0:
		against = "%+.0f pts vs the Greedy control" % (100.0 * (float(rate) - _baseline))
	if rate != null and int(headline.get("games", 0)) == 0:
		if against.is_empty():
			against = "estimate, not a measured sweep"
		else:
			against += " · estimate, not a measured sweep"
	if not against.is_empty():
		var against_label := Label.new()
		against_label.text = against
		against_label.modulate = COL_DIM
		box.add_child(against_label)

	box.add_child(_prose(str(entry.get("summary", "")), Color.WHITE))

	var variants := _variant_line(entry)
	if not variants.is_empty():
		var variant_label := Label.new()
		variant_label.text = variants
		variant_label.modulate = COL_DIM
		box.add_child(variant_label)

	var capabilities: Variant = entry.get("capabilities", [])
	if capabilities is Array and not (capabilities as Array).is_empty():
		box.add_child(_bullets(capabilities as Array, "+", "#73d97f"))
	var limits: Variant = entry.get("limits", [])
	if limits is Array and not (limits as Array).is_empty():
		box.add_child(_bullets(limits as Array, "−", "#ffb852"))

	var metrics: Variant = entry.get("metrics", {})
	if metrics is Dictionary and not (metrics as Dictionary).is_empty():
		box.add_child(_metric_grid(metrics as Dictionary))

	return panel


## The dropdown labels carry a "(needs mtgai.serve ...)" hint. This screen says
## that better, and live, in the status beside the name.
func _display_name(id: String) -> String:
	var label := str(GameConfig.AGENT_TYPES.get(id, id))
	var hint := label.find(" (needs")
	if hint > 0:
		return label.substr(0, hint)
	return label


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL
	style.set_corner_radius_all(8)
	style.border_color = Color(1, 1, 1, 0.07)
	style.set_border_width_all(1)
	return style


func _bar(id: String, rate: Variant) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 8)
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.value = 0.0 if rate == null else float(rate)

	var background := StyleBoxFlat.new()
	background.bg_color = Color(1, 1, 1, 0.06)
	background.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", background)

	var fill := StyleBoxFlat.new()
	fill.bg_color = Color.TRANSPARENT if rate == null else _rate_colour(id, float(rate))
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


## Green at or above the control, amber within reach of it, red below. The
## control itself is blue, because beating it by a point is not the same kind of
## fact as being it.
func _rate_colour(id: String, rate: float) -> Color:
	if id == "greedy":
		return COL_BASELINE
	if _baseline <= 0.0:
		return COL_READY
	if rate >= _baseline - 0.02:
		return COL_READY
	if rate >= _baseline * 0.6:
		return COL_WAITING
	return COL_BROKEN


## Is this agent runnable right now? `requires` is "", "policy" or "value".
func _status(requires: String) -> Dictionary:
	if requires.is_empty():
		return {"text": "no server needed", "color": COL_DIM}
	if _health.is_empty():
		return {"text": "server offline — would play as Greedy", "color": COL_WAITING}
	if not _health.get(requires, false):
		return {"text": "server up, no %s net loaded" % requires, "color": COL_WAITING}
	var served := int(_health.get("feature_count", 0))
	var expected := StateEncoder.feature_count()
	if served != expected:
		# Changing state_encoder.gd invalidates every checkpoint. Better to say
		# so than to play badly and let the model take the blame.
		return {
			"text": "encoding mismatch: model wants %d features, this build encodes %d" % [served, expected],
			"color": COL_BROKEN,
		}
	return {"text": "ready", "color": COL_READY}


func _prose(text: String, colour: Color) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = colour
	label.text = text
	return label


func _bullets(items: Array, marker: String, hex: String) -> RichTextLabel:
	var lines: Array[String] = []
	for item in items:
		lines.append("[color=%s]%s[/color]  %s" % [hex, marker, str(item)])
	return _prose("\n".join(lines), Color(1, 1, 1, 0.85))


## Extra measured settings for the same agent — search depths, blends.
func _variant_line(entry: Dictionary) -> String:
	var results: Variant = entry.get("results", [])
	if not (results is Array) or (results as Array).size() < 2:
		return ""
	var parts: Array[String] = []
	for i in range(1, (results as Array).size()):
		var row: Variant = (results as Array)[i]
		if not (row is Dictionary):
			continue
		var value: Variant = (row as Dictionary).get("win_rate")
		var shown := "—"
		if value != null:
			shown = "%.0f%%" % (100.0 * float(value))
		parts.append("%s %s" % [str((row as Dictionary).get("label", "?")), shown])
	if parts.is_empty():
		return ""
	return "Other settings measured: " + ", ".join(parts)


func _metric_grid(metrics: Dictionary) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 2)
	for key in metrics:
		var key_label := Label.new()
		key_label.text = str(key)
		key_label.modulate = COL_DIM
		grid.add_child(key_label)

		var value_label := Label.new()
		value_label.text = str(metrics[key])
		grid.add_child(value_label)
	return grid
