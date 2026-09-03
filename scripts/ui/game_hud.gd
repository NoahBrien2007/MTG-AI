class_name GameHUD
extends CanvasLayer

## 2D overlay for the game: life totals, phase, prompt, action log, card
## preview, choice dialog and buttons. Contains no game logic — it only reports
## what the player pressed to the controller.

signal pass_pressed
signal confirm_pressed
signal cancel_pressed
signal player_clicked(player_id: int)
signal choice_selected(index: int)
signal auto_pass_toggled(enabled: bool)
signal play_again_pressed
signal main_menu_pressed

const COLOR_TARGETABLE := Color(1.0, 0.85, 0.3)

@onready var lbl_turn: Label = $TopBar/HBox/LblTurn
@onready var lbl_phase: Label = $TopBar/HBox/LblPhase
@onready var lbl_opp_info: Label = $TopBar/HBox/LblOppInfo
@onready var btn_opponent: Button = $TopBar/HBox/BtnOpponent
@onready var btn_menu: Button = $TopBar/HBox/BtnMenu
@onready var prompt_panel: PanelContainer = $PromptPanel
@onready var prompt: Label = $PromptPanel/Prompt
@onready var hint: Label = $Hint
@onready var log_panel: PanelContainer = $LogPanel
@onready var log_label: RichTextLabel = $LogPanel/Log
@onready var preview_panel: PanelContainer = $Preview
@onready var preview_header: HBoxContainer = $Preview/VBox/Header
@onready var preview_title: Label = $Preview/VBox/Header/LblTitle
@onready var btn_preview_close: Button = $Preview/VBox/Header/BtnClose
@onready var preview_image: TextureRect = $Preview/VBox/Image
@onready var preview_text: RichTextLabel = $Preview/VBox/Text
@onready var choices_panel: PanelContainer = $Choices
@onready var lbl_choice_title: Label = $Choices/VBox/LblChoiceTitle
@onready var choice_content: VBoxContainer = $Choices/VBox/Scroll/Content
@onready var btn_you: Button = $BottomBar/HBox/BtnYou
@onready var lbl_mana: Label = $BottomBar/HBox/LblMana
@onready var lbl_you_info: Label = $BottomBar/HBox/LblYouInfo
@onready var chk_auto_pass: CheckBox = $BottomBar/HBox/ChkAutoPass
@onready var btn_cancel: Button = $BottomBar/HBox/BtnCancel
@onready var btn_confirm: Button = $BottomBar/HBox/BtnConfirm
@onready var btn_pass: Button = $BottomBar/HBox/BtnPass
@onready var game_over_panel: PanelContainer = $GameOver
@onready var lbl_result: Label = $GameOver/VBox/LblResult
@onready var btn_play_again: Button = $GameOver/VBox/Buttons/BtnPlayAgain
@onready var btn_main_menu: Button = $GameOver/VBox/Buttons/BtnMainMenu

var human_player: int = 0
var preview_pinned: bool = false
var _preview_name: String = ""


func _ready() -> void:
	btn_pass.pressed.connect(func() -> void: pass_pressed.emit())
	btn_confirm.pressed.connect(func() -> void: confirm_pressed.emit())
	btn_cancel.pressed.connect(func() -> void: cancel_pressed.emit())
	btn_you.pressed.connect(func() -> void: player_clicked.emit(human_player))
	btn_opponent.pressed.connect(func() -> void: player_clicked.emit(1 - human_player))
	chk_auto_pass.toggled.connect(func(on: bool) -> void: auto_pass_toggled.emit(on))
	btn_play_again.pressed.connect(func() -> void: play_again_pressed.emit())
	btn_main_menu.pressed.connect(func() -> void: main_menu_pressed.emit())
	btn_menu.pressed.connect(func() -> void: main_menu_pressed.emit())
	btn_preview_close.pressed.connect(unpin_card_preview)
	# Keyboard shortcuts are handled by the game controller; keep buttons from grabbing focus.
	for button in [btn_pass, btn_confirm, btn_cancel, btn_you, btn_opponent, btn_menu, chk_auto_pass, btn_preview_close]:
		button.focus_mode = Control.FOCUS_NONE
	set_controls(false, "", false)
	set_players_targetable([])
	hide_choices()
	unpin_card_preview()
	set_prompt("")


# ───────────────────────────── Prompt & buttons ─────────────────────────────

func set_prompt(text: String, hint_text: String = "") -> void:
	prompt.text = text
	hint.text = hint_text
	prompt_panel.visible = not text.is_empty()


## pass_enabled: Pass button clickable. confirm_text: label of the confirm button
## ("" hides it). cancel_visible: show the cancel button.
func set_controls(pass_enabled: bool, confirm_text: String = "", cancel_visible: bool = false) -> void:
	btn_pass.disabled = not pass_enabled
	btn_confirm.visible = not confirm_text.is_empty()
	btn_confirm.text = confirm_text
	btn_cancel.visible = cancel_visible


## Enables the life-total buttons of the given players as spell targets.
func set_players_targetable(player_ids: Array[int]) -> void:
	for pid: int in [human_player, 1 - human_player]:
		var button: Button = btn_you if pid == human_player else btn_opponent
		var targetable: bool = player_ids.has(pid)
		button.disabled = not targetable
		button.modulate = COLOR_TARGETABLE if targetable else Color.WHITE


# ───────────────────────────── Choice dialog ─────────────────────────────

const CHOICE_CARD_SIZE := Vector2(170, 237)

## Shows a list of labelled options; emits choice_selected(index) when one is clicked.
## `card_names[i]` (optional) shows the card's image above option i; options that
## share a card are grouped under one image (e.g. scry: keep / bottom).
func show_choices(title: String, labels: PackedStringArray, card_names: PackedStringArray = PackedStringArray()) -> void:
	for child in choice_content.get_children():
		choice_content.remove_child(child)
		child.queue_free()
	lbl_choice_title.text = title

	var has_cards := false
	for name in card_names:
		if not name.is_empty():
			has_cards = true
			break

	if not has_cards:
		for i in range(labels.size()):
			choice_content.add_child(_choice_button(labels[i], i))
		choices_panel.visible = true
		return

	# Group options by card, one column per card, laid out horizontally.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	choice_content.add_child(row)
	var columns: Dictionary = {} # card name -> VBoxContainer
	for i in range(labels.size()):
		var card_name: String = card_names[i] if i < card_names.size() else ""
		if not columns.has(card_name):
			var column := VBoxContainer.new()
			column.add_theme_constant_override("separation", 6)
			if not card_name.is_empty():
				var image := TextureRect.new()
				image.custom_minimum_size = CHOICE_CARD_SIZE
				image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				column.add_child(image)
				var caption := Label.new()
				caption.text = card_name
				caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				caption.custom_minimum_size = Vector2(CHOICE_CARD_SIZE.x, 0)
				column.add_child(caption)
				CardTextures.fetch(card_name, func(texture: Texture2D) -> void:
					if is_instance_valid(image) and texture:
						image.texture = texture)
			row.add_child(column)
			columns[card_name] = column
		var column: VBoxContainer = columns[card_name]
		var label := labels[i]
		if not card_name.is_empty():
			# "Take Opt" under Opt's picture is redundant: shorten to the verb.
			label = label.replace(" " + card_name, "").replace(card_name, "").strip_edges()
			if label.is_empty():
				label = "Choose"
		column.add_child(_choice_button(label, i))
	choices_panel.visible = true


func _choice_button(text: String, index: int) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 36)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func() -> void: choice_selected.emit(index))
	return button


func hide_choices() -> void:
	choices_panel.visible = false


func choices_visible() -> bool:
	return choices_panel.visible


# ───────────────────────────── Card preview ─────────────────────────────

## Hover preview: just the card image. Ignored while a card is pinned.
func show_card_preview(card: CardInstance) -> void:
	if preview_pinned:
		return
	_show_preview(card, false)


## Double-click preview: image + scrollable rules text, stays until closed.
func pin_card_preview(card: CardInstance) -> void:
	preview_pinned = true
	_show_preview(card, true)


func unpin_card_preview() -> void:
	preview_pinned = false
	hide_card_preview()


func hide_card_preview() -> void:
	if preview_pinned:
		return
	_preview_name = ""
	preview_panel.visible = false


func _show_preview(card: CardInstance, detailed: bool) -> void:
	if card == null or card.definition == null:
		preview_pinned = false
		hide_card_preview()
		return
	var def := card.definition
	_preview_name = def.card_name
	preview_panel.visible = true
	preview_header.visible = detailed
	preview_text.visible = detailed
	preview_title.text = def.card_name

	if detailed:
		var lines: PackedStringArray = []
		lines.append("[b]%s[/b]  [color=#c9b458]%s[/color]" % [def.card_name, def.mana_cost])
		lines.append("[color=#9fb3c8]%s[/color]" % (def.type_line if not def.type_line.is_empty() else def.type_name()))
		if card.is_creature():
			var pt := "%d/%d" % [card.get_power(), card.get_toughness()]
			if card.damage_marked > 0:
				pt += "  [color=#ff8a8a](%d damage)[/color]" % card.damage_marked
			lines.append("[b]%s[/b]" % pt)
		var mana_colors: PackedStringArray = []
		for ability in card.mana_abilities():
			mana_colors.append(ability["color"])
		if not mana_colors.is_empty():
			lines.append("Taps for: %s" % " ".join(mana_colors))
		if not def.oracle_text.is_empty():
			lines.append("")
			lines.append(def.oracle_text)
		var status: PackedStringArray = []
		if card.tapped:
			status.append("tapped")
		if card.summoned_this_turn and card.is_creature():
			status.append("summoning sick")
		if card.class_level > 0:
			status.append("level %d" % card.class_level)
		if not card.chosen_land_type.is_empty():
			status.append(card.chosen_land_type)
		if card.is_land_until_next_turn:
			status.append("currently a land")
		for kw in card.temp_keywords:
			status.append(kw + " until end of turn")
		if card.temp_power_bonus != 0 or card.temp_toughness_bonus != 0:
			status.append("%+d/%+d until end of turn" % [card.temp_power_bonus, card.temp_toughness_bonus])
		if not status.is_empty():
			lines.append("")
			lines.append("[color=#9fb3c8][i]%s[/i][/color]" % ", ".join(status))
		preview_text.text = "\n".join(lines)

	preview_image.texture = null
	CardTextures.fetch(def.card_name, _on_preview_texture.bind(def.card_name))


func _on_preview_texture(texture: Texture2D, card_name: String) -> void:
	# Ignore textures that arrive after the preview moved on to another card.
	if card_name == _preview_name and texture:
		preview_image.texture = texture


# ───────────────────────────── State display ─────────────────────────────

func update_state(state: MTGGameState) -> void:
	var you := state.players[human_player]
	var opp := state.players[1 - human_player]

	lbl_turn.text = "Turn %d — %s" % [state.turn_number, "your turn" if state.active_player == human_player else "opponent's turn"]
	lbl_phase.text = state.step_name()
	if not state.stack.is_empty():
		lbl_phase.text += "  ·  %d on the stack" % state.stack.size()

	btn_you.text = "You  ♥ %d" % you.life
	btn_opponent.text = "Opponent  ♥ %d" % opp.life
	lbl_mana.text = "Mana: %s" % you.mana_pool_text()
	lbl_you_info.text = "Library %d · Graveyard %d" % [you.library.size(), you.graveyard.size()]
	lbl_opp_info.text = "Hand %d · Library %d · Graveyard %d" % [opp.hand.size(), opp.library.size(), opp.graveyard.size()]


func log_line(text: String, color: String = "") -> void:
	if color.is_empty():
		log_label.append_text(text + "\n")
	else:
		log_label.append_text("[color=%s]%s[/color]\n" % [color, text])


func show_game_over(text: String) -> void:
	lbl_result.text = text
	game_over_panel.visible = true
	set_controls(false, "", false)
	set_players_targetable([])
	hide_choices()


func toggle_log() -> void:
	log_panel.visible = not log_panel.visible
