extends Node3D

## Root script of Game.tscn. Wires the HumanAgent to mouse input and the HUD.
##
## Everything the player does ends up as a plain MTGAction handed to the
## HumanAgent — the same action objects the AI agents return — so the UI can
## never do anything an AI could not.
##
## Interaction modes:
##   CHOOSING   normal priority window: click cards, pass
##   PLACING    a permanent was picked: click a grid cell to drop it on
##   TARGETING  a spell/ability needs targets: click them one slot at a time
##   ATTACKERS  toggle attacking creatures, confirm
##   BLOCKING   pick blocker then attacker, confirm when done
##   CHOICE     a labelled list (pending effect choice, land options, kicker…)

enum Mode { IDLE, CHOOSING, PLACING, TARGETING, ATTACKERS, BLOCKING, CHOICE }

const COLOR_PLAYABLE := Color(0.35, 1.0, 0.45, 0.9)
const COLOR_SELECTED := Color(1.0, 0.85, 0.2, 0.95)
const COLOR_TARGET := Color(1.0, 0.6, 0.15, 0.9)
const COLOR_DROP_CELL := Color(0.35, 1.0, 0.45, 0.35)
const COLOR_ATTACK_PICK := Color(1.0, 0.35, 0.3, 0.9)
const COLOR_BLOCK_PICK := Color(0.4, 0.6, 1.0, 0.9)

@export var ai_delay: float = 0.7

@onready var board: BoardView = $BoardView
@onready var grid: BoardGrid = $Table/PlayfieldBoards
@onready var camera: Camera3D = $Camera3D
@onready var hud: GameHUD = $GameHUD

var session: GameSession
var human: HumanAgent
var opponent: BaseAgent

var mode: Mode = Mode.IDLE
var legal: Array[MTGAction] = []

# Selection state
var selected_card: CardInstance
## Candidate plays for the selected card. Each option: {"sequence": Array[MTGAction], "final": MTGAction}
var options: Array = []
var picked_targets: Array = []          # target slots chosen so far (TARGETING)
var drop_cells: Array[Vector2i] = []
var attackers_picked: Array[int] = []
var selected_blocker: int = -1
var choice_actions: Array = []          # what each button of the choice dialog submits (CHOICE)
var targeting_name: String = ""         # what is being targeted for (prompt text)
var targeting_mandatory: bool = false   # pending trigger targets can't be cancelled
var _choice_pending_cell: bool = false  # choice dialog opened from PLACING (land options)

var _preview_id: int = -1
var _pinned_id: int = -1


func _ready() -> void:
	board.human_player = 0
	hud.human_player = 0

	human = HumanAgent.new(0)
	human.auto_pass = hud.chk_auto_pass.button_pressed
	human.decision_requested.connect(_on_decision_requested)

	opponent = GameConfig.create_agent(GameConfig.opponent_agent, 1)

	session = GameSession.new()
	session.setup(GameConfig.player_deck_path, GameConfig.opponent_deck_path, human, opponent)
	session.action_applied.connect(_on_action_applied)
	session.finished.connect(_on_finished)

	hud.pass_pressed.connect(_on_pass)
	hud.confirm_pressed.connect(_on_confirm)
	hud.cancel_pressed.connect(_cancel_selection)
	hud.player_clicked.connect(_on_player_clicked)
	hud.choice_selected.connect(_on_choice_selected)
	hud.auto_pass_toggled.connect(func(on: bool) -> void: human.auto_pass = on)
	hud.play_again_pressed.connect(func() -> void: get_tree().reload_current_scene())
	hud.main_menu_pressed.connect(_on_main_menu)

	hud.log_line("You: %s" % GameConfig.deck_display_name(GameConfig.player_deck_path), "#9fd3ff")
	hud.log_line("Opponent (%s): %s" % [opponent.agent_name, GameConfig.deck_display_name(GameConfig.opponent_deck_path)], "#ffb3a7")

	board.sync(session.state)
	hud.update_state(session.state)
	session.run_async(get_tree(), ai_delay)


func _exit_tree() -> void:
	if session:
		session.abort()


# ───────────────────────────── Session events ─────────────────────────────

func _on_action_applied(action: MTGAction, description: String, state: MTGGameState) -> void:
	board.sync(state)
	hud.update_state(state)
	_preview_id = -1 # card stats may have changed; refresh the preview on the next frame
	if hud.preview_pinned:
		_refresh_pinned_preview(state)
	hud.log_line(description, "#cfe3ff" if action.player_id == 0 else "#ffd6cf")
	if mode == Mode.IDLE and not state.game_over:
		hud.set_prompt("Opponent is thinking…" if state.acting_player() != 0 else "")


func _on_finished(state: MTGGameState) -> void:
	_set_mode(Mode.IDLE)
	var text := "Draw"
	if state.winner_id == 0:
		text = "You win!"
	elif state.winner_id == 1:
		text = "You lose."
	elif not state.game_over:
		text = "Game stopped (action limit reached)."
	hud.log_line(text, "#ffe08a")
	hud.show_game_over(text)


func _on_decision_requested(state: MTGGameState, legal_actions: Array[MTGAction]) -> void:
	legal = legal_actions
	if state.has_pending_choice():
		if state.pending_choice["kind"] == "targets" and _pending_targets_on_board(state):
			_enter_targeting_from_pending(state, legal_actions)
		else:
			_enter_choice(_pending_title(state), legal_actions, false, _pending_card_names(state, legal_actions))
	elif _has_action(MTGAction.ActionType.DECLARE_ATTACKERS):
		_enter_attackers()
	elif _has_action(MTGAction.ActionType.DECLARE_BLOCKER) or _has_action(MTGAction.ActionType.FINISH_COMBAT_DECLARATIONS):
		_enter_blocking()
	else:
		_enter_choosing()


func _pending_title(state: MTGGameState) -> String:
	var source := state.find_card_instance(state.pending_choice.get("ctx", {}).get("source", -1))
	var name := source.definition.card_name if source and source.definition else "Effect"
	match state.pending_choice.get("kind", ""):
		"scry":
			return "%s — scry" % name
		"pick_card":
			return "%s — choose a card to take" % name
		"pay_or_not":
			return "%s — pay?" % name
		"targets":
			return "%s — choose targets" % name
	return name


## True if every card among the pending target options sits on the battlefield or
## the stack, i.e. can be clicked on the table (graveyard cards use the image picker).
func _pending_targets_on_board(state: MTGGameState) -> bool:
	for option in state.pending_choice["options"]:
		for slot in option.get("slots", []):
			if slot.has("card"):
				var zone: String = state.find_card_location(slot["card"]).get("zone_name", "")
				if zone != "battlefield" and zone != "stack":
					return false
	return true


## Card to picture next to each pending-choice option ("" = none).
func _pending_card_names(state: MTGGameState, choose_actions: Array[MTGAction]) -> PackedStringArray:
	var names: PackedStringArray = []
	var pending := state.pending_choice
	var data: Dictionary = pending.get("data", {})
	for action in choose_actions:
		var option: Dictionary = pending["options"][action.choice_index]
		var card_id := -1
		match pending["kind"]:
			"scry":
				card_id = data["cards"][data["index"]]
			"pick_card":
				card_id = option.get("card", -1)
			"pay_or_not":
				card_id = data.get("spell", -1)
			"targets":
				var slots: Array = option.get("slots", [])
				if slots.size() == 1 and slots[0].has("card"):
					card_id = slots[0]["card"]
		var card := state.find_card_instance(card_id)
		names.append(card.definition.card_name if card and card.definition else "")
	return names


# ───────────────────────────── Modes ─────────────────────────────

func _set_mode(new_mode: Mode) -> void:
	mode = new_mode
	board.clear_cell_highlights()
	board.clear_card_highlights()
	grid.set_forced_visible(false)
	hud.set_players_targetable([])
	hud.hide_choices()
	board.set_dim(false)
	board.clear_spotlight()
	# Restore combat highlights that clear_card_highlights() removed.
	board.sync(session.state)


func _enter_choosing() -> void:
	_set_mode(Mode.CHOOSING)
	selected_card = null
	options.clear()

	var state := session.state
	var playable: Array[int] = []
	for card in state.players[0].hand:
		if not _play_options_for(card).is_empty():
			playable.append(card.instance_id)
	for card in state.players[0].battlefield:
		if not _ability_options_for(card).is_empty():
			playable.append(card.instance_id)
	board.highlight_cards(playable, COLOR_PLAYABLE)

	var own_turn := state.active_player == 0
	var prompt: String = ("Your turn — %s" % state.step_name()) if own_turn else ("Opponent's %s — you have priority" % state.step_name())
	if not state.stack.is_empty():
		var top: CardInstance = state.stack[state.stack.size() - 1]["card"]
		prompt += "  ·  %s on the stack (pass to resolve)" % top.definition.card_name
	var hint := "Click a highlighted card to play it · click a land to tap it · Space to pass"
	if playable.is_empty():
		hint = "Nothing to play — pass with Space"
	hud.set_prompt(prompt, hint)
	hud.set_controls(true, "", false)


func _enter_placing(card: CardInstance, play_options: Array) -> void:
	_set_mode(Mode.PLACING)
	selected_card = card
	options = play_options
	drop_cells = board.drop_cells_for(card, 0)
	board.highlight_cards([card.instance_id], COLOR_SELECTED)
	board.highlight_cells(drop_cells, COLOR_DROP_CELL)
	grid.set_forced_visible(true)
	hud.set_prompt("Choose a cell for %s" % card.definition.card_name, "Click a highlighted slot on the grid · Esc to cancel")
	hud.set_controls(false, "", true)


func _enter_targeting(card: CardInstance, play_options: Array) -> void:
	_set_mode(Mode.TARGETING)
	selected_card = card
	targeting_name = card.definition.card_name
	targeting_mandatory = false
	options = play_options
	picked_targets = []
	_refresh_targeting()


## A triggered ability (e.g. Eddymurk Crab's ETB) wants targets: pick them on the
## table exactly like spell targets. Each CHOOSE action stands for one target set.
func _enter_targeting_from_pending(state: MTGGameState, choose_actions: Array[MTGAction]) -> void:
	_set_mode(Mode.TARGETING)
	var source := state.find_card_instance(state.pending_choice.get("ctx", {}).get("source", -1))
	selected_card = source
	targeting_name = source.definition.card_name if source and source.definition else "Ability"
	targeting_mandatory = true
	options = []
	for action in choose_actions:
		var slots: Array = state.pending_choice["options"][action.choice_index].get("slots", [])
		var typed: Array[Dictionary] = []
		for slot in slots:
			typed.append(slot)
		action.targets = typed # only used by the UI; CHOOSE actions match on choice_index
		options.append({"sequence": [action], "final": action, "cost": {}})
	picked_targets = []
	_refresh_targeting()


## Highlights the candidates for the next target slot given what was picked so far.
func _refresh_targeting() -> void:
	var remaining := _remaining_options()
	if remaining.is_empty():
		_enter_choosing()
		return
	# Only one way left to play it → done (kicker choice handled by _finish_play).
	var distinct_targets := {}
	for option in remaining:
		distinct_targets[JSON.stringify(option["final"].targets)] = true
	if distinct_targets.size() == 1:
		_finish_play(remaining)
		return

	board.clear_card_highlights()
	board.sync(session.state)
	var spotlit: Array[int] = []
	if selected_card:
		board.highlight_cards([selected_card.instance_id], COLOR_SELECTED)
		spotlit.append(selected_card.instance_id)
	for slot in picked_targets:
		if slot.has("card"):
			board.highlight_cards([slot["card"]], COLOR_TARGET)
			spotlit.append(slot["card"])

	var target_cards: Array[int] = []
	var target_players: Array[int] = []
	var can_finish := false
	for option in remaining:
		var targets: Array = option["final"].targets
		if targets.size() == picked_targets.size():
			can_finish = true
			continue
		var slot: Dictionary = targets[picked_targets.size()]
		if slot.has("card") and not target_cards.has(slot["card"]):
			target_cards.append(slot["card"])
		elif slot.has("player") and not target_players.has(slot["player"]):
			target_players.append(slot["player"])
	board.highlight_cards(target_cards, COLOR_TARGET)
	spotlit.append_array(target_cards)
	board.spotlight_cards(spotlit)
	board.set_dim(true)
	hud.set_players_targetable(target_players)

	var n := picked_targets.size() + 1
	var hint := "Click a highlighted card or life total"
	if not targeting_mandatory:
		hint += " · Esc to cancel"
	if can_finish:
		hint += " · Confirm to stop adding targets" if n > 1 else " · Confirm to choose no target"
	hud.set_prompt("%s — choose target %d" % [targeting_name, n], hint)
	hud.set_controls(false, ("Done choosing targets" if n > 1 else "No target") if can_finish else "", not targeting_mandatory)


func _enter_attackers() -> void:
	_set_mode(Mode.ATTACKERS)
	attackers_picked.clear()
	board.highlight_cards(_eligible_attackers(), COLOR_ATTACK_PICK)
	hud.set_prompt("Declare attackers", "Click creatures to toggle them · Confirm to attack (nobody selected = no attack)")
	hud.set_controls(false, "No attack  (Enter)", false)


func _enter_blocking() -> void:
	_set_mode(Mode.BLOCKING)
	selected_blocker = -1
	board.highlight_cards(_blocker_candidates(), COLOR_BLOCK_PICK)
	hud.set_prompt("Declare blockers", "Click one of your creatures, then the attacker it blocks · Done when finished")
	hud.set_controls(false, "Done blocking  (Enter)", false)


## Shows a list of labelled actions. `actions` may be MTGActions (submitted
## directly) or option dictionaries (sequences, see _submit_option).
func _enter_choice(title: String, actions: Array, cancellable: bool, card_names: PackedStringArray = PackedStringArray()) -> void:
	_set_mode(Mode.CHOICE)
	choice_actions = actions
	var labels: PackedStringArray = []
	for a in actions:
		labels.append(_option_label(a))
	hud.show_choices(title, labels, card_names)
	hud.set_prompt(title, "Esc to cancel" if cancellable else "")
	hud.set_controls(false, "", cancellable)


func _option_label(a) -> String:
	if a is MTGAction:
		return a.label if not a.label.is_empty() else a.describe(session.state)
	var final: MTGAction = a["final"]
	var text := final.label if not final.label.is_empty() else final.describe(session.state)
	var cost: Dictionary = a.get("cost", {})
	if not cost.is_empty():
		text += "   %s" % Costs.to_text(cost)
	return text


# ───────────────────────────── Input ─────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click:
			_pin_card_under_mouse(event.position)
		else:
			_handle_click(event.position)
		return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				if mode == Mode.CHOOSING:
					_on_pass()
			KEY_ENTER, KEY_KP_ENTER:
				_on_confirm()
			KEY_ESCAPE:
				if hud.preview_pinned:
					hud.unpin_card_preview()
				else:
					_cancel_selection()
			KEY_L:
				hud.toggle_log()


func _process(_delta: float) -> void:
	# Lift the hand card under the mouse and preview whatever face-up card is hovered.
	var mouse := get_viewport().get_mouse_position()
	var node := board.pick_card(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))
	if node == null or not node.face_up:
		board.set_hovered(null)
		_set_preview(null)
		return
	var zone: String = _location(node.card_instance.instance_id).get("zone_name", "")
	var in_own_hand: bool = node.card_instance.owner_id == 0 and zone == "hand"
	board.set_hovered(node if in_own_hand else null)
	_set_preview(node.card_instance)


func _refresh_pinned_preview(state: MTGGameState) -> void:
	var loc := state.find_card_location(_pinned_id)
	if loc.is_empty():
		hud.unpin_card_preview()
	else:
		hud.pin_card_preview(loc["card"])


## Double-click: pin the detailed preview of the card under the mouse.
func _pin_card_under_mouse(screen_pos: Vector2) -> void:
	var node := board.pick_card(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if node and node.face_up:
		_preview_id = node.card_instance.instance_id
		_pinned_id = _preview_id
		hud.pin_card_preview(node.card_instance)


func _set_preview(card: CardInstance) -> void:
	var id := card.instance_id if card else -1
	if id == _preview_id:
		return
	_preview_id = id
	if card:
		hud.show_card_preview(card)
	else:
		hud.hide_card_preview()


func _handle_click(screen_pos: Vector2) -> void:
	if mode == Mode.IDLE or mode == Mode.CHOICE:
		return
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var node := board.pick_card(origin, direction)
	var card: CardInstance = node.card_instance if node else null

	match mode:
		Mode.CHOOSING:
			if card:
				_click_card_choosing(card)

		Mode.PLACING:
			var cell := board.pick_cell(origin, direction)
			if cell in drop_cells:
				_commit_placement(cell)
			elif card and card.owner_id == 0 and _location(card.instance_id).get("zone_name", "") == "hand":
				_enter_choosing()
				_click_card_choosing(card)

		Mode.TARGETING:
			if card:
				_pick_target({"card": card.instance_id})

		Mode.ATTACKERS:
			if card and card.instance_id in _eligible_attackers():
				if card.instance_id in attackers_picked:
					attackers_picked.erase(card.instance_id)
				else:
					attackers_picked.append(card.instance_id)
				board.highlight_cards(_eligible_attackers(), COLOR_ATTACK_PICK)
				board.highlight_cards(attackers_picked, COLOR_SELECTED)
				var label := "Attack with %d  (Enter)" % attackers_picked.size() if not attackers_picked.is_empty() else "No attack  (Enter)"
				hud.set_controls(false, label, false)

		Mode.BLOCKING:
			if not card:
				return
			if card.instance_id in _blocker_candidates():
				selected_blocker = card.instance_id
				board.highlight_cards(_blocker_candidates(), COLOR_BLOCK_PICK)
				board.highlight_cards([selected_blocker], COLOR_SELECTED)
				board.highlight_cards(_attackers_blockable_by(selected_blocker), COLOR_TARGET)
				hud.set_prompt("Declare blockers", "Now click the attacker %s should block" % card.definition.card_name)
			elif selected_blocker != -1 and card.instance_id in _attackers_blockable_by(selected_blocker):
				var act := MTGAction.new(MTGAction.ActionType.DECLARE_BLOCKER, 0)
				act.blocker_id = selected_blocker
				act.blocking_attacker_id = card.instance_id
				_submit(act)


func _click_card_choosing(card: CardInstance) -> void:
	var loc := _location(card.instance_id)
	if loc.is_empty() or loc["player"].player_id != 0:
		return

	if loc["zone_name"] == "hand":
		var play_options := _play_options_for(card)
		if play_options.is_empty():
			var reason := "not enough mana"
			if not card.definition.is_land() and not session.engine.is_cast_timing_legal(session.state, 0, card):
				reason = "not the right moment"
			elif card.definition.is_land():
				reason = "you already played a land" if session.state.land_played_this_turn else "not the right moment"
			hud.set_prompt("Can't play %s right now (%s)" % [card.definition.card_name, reason])
			return
		if card.definition.is_permanent():
			_enter_placing(card, play_options)
		else:
			_enter_targeting(card, play_options)

	elif loc["zone_name"] == "battlefield":
		var choices: Array = []
		for tap in legal:
			if tap.action_type == MTGAction.ActionType.TAP_LAND and tap.card_instance_id == card.instance_id:
				tap.label = "Tap for %s" % tap.mana_color
				choices.append(tap)
		choices.append_array(_ability_options_for(card))
		if choices.is_empty():
			return
		if choices.size() == 1:
			_submit_any(choices[0])
		else:
			selected_card = card
			_enter_choice(card.definition.card_name, choices, true)


func _pick_target(slot: Dictionary) -> void:
	var matches := false
	for option in _remaining_options():
		var targets: Array = option["final"].targets
		if targets.size() > picked_targets.size() and _same_target(targets[picked_targets.size()], slot):
			matches = true
			break
	if not matches:
		return
	# Store the slot as the engine wrote it (with its "spec" index) so prefixes compare equal.
	for option in _remaining_options():
		var targets: Array = option["final"].targets
		if targets.size() > picked_targets.size() and _same_target(targets[picked_targets.size()], slot):
			picked_targets.append(targets[picked_targets.size()])
			break
	_refresh_targeting()


func _same_target(a: Dictionary, b: Dictionary) -> bool:
	return a.get("card", -1) == b.get("card", -1) and a.get("player", -1) == b.get("player", -1)


## Options whose target list starts with the targets picked so far.
func _remaining_options() -> Array:
	var result: Array = []
	for option in options:
		var targets: Array = option["final"].targets
		if targets.size() < picked_targets.size():
			continue
		var ok := true
		for i in range(picked_targets.size()):
			if not _same_target(targets[i], picked_targets[i]):
				ok = false
				break
		if ok:
			result.append(option)
	return result


## Targets are settled; if several variants remain (kicker, land options) ask, else submit.
func _finish_play(remaining: Array) -> void:
	if remaining.size() == 1:
		_submit_option(remaining[0])
	else:
		_enter_choice("How do you want to play %s?" % targeting_name, remaining, not targeting_mandatory)


func _commit_placement(cell: Vector2i) -> void:
	if selected_card == null or options.is_empty():
		return
	board.reserve_cell(selected_card.instance_id, cell)
	if options.size() == 1:
		if not _submit_option(options[0]):
			board.release_cell(selected_card.instance_id)
	else:
		_choice_pending_cell = true
		_enter_choice("How does %s enter?" % selected_card.definition.card_name, options, true)


func _cancel_selection() -> void:
	match mode:
		Mode.PLACING:
			_enter_choosing()
		Mode.TARGETING:
			if not targeting_mandatory:
				_enter_choosing()
		Mode.CHOICE:
			if hud.btn_cancel.visible:
				if _choice_pending_cell and selected_card:
					board.release_cell(selected_card.instance_id)
				_choice_pending_cell = false
				_enter_choosing()
		Mode.BLOCKING:
			selected_blocker = -1
			_enter_blocking()
		Mode.ATTACKERS:
			_enter_attackers()


func _on_pass() -> void:
	if mode != Mode.CHOOSING:
		return
	var act := human.find_legal(MTGAction.ActionType.PASS_PRIORITY)
	if act:
		_submit(act)


func _on_confirm() -> void:
	match mode:
		Mode.ATTACKERS:
			var act := MTGAction.new(MTGAction.ActionType.DECLARE_ATTACKERS, 0)
			act.attacker_ids = attackers_picked.duplicate()
			_submit(act)
		Mode.BLOCKING:
			var act := human.find_legal(MTGAction.ActionType.FINISH_COMBAT_DECLARATIONS)
			if act:
				_submit(act)
		Mode.TARGETING:
			var complete: Array = []
			for option in _remaining_options():
				if option["final"].targets.size() == picked_targets.size():
					complete.append(option)
			if not complete.is_empty():
				_finish_play(complete)


func _on_player_clicked(player_id: int) -> void:
	if mode == Mode.TARGETING:
		_pick_target({"player": player_id})


func _on_choice_selected(index: int) -> void:
	if mode != Mode.CHOICE or index < 0 or index >= choice_actions.size():
		return
	var was_cell := _choice_pending_cell
	_choice_pending_cell = false
	if not _submit_any(choice_actions[index]) and was_cell and selected_card:
		board.release_cell(selected_card.instance_id)


func _on_main_menu() -> void:
	session.abort()
	GameConfig.go_to(GameConfig.SCENE_MAIN_MENU)


# ───────────────────────────── Submitting ─────────────────────────────

func _submit_any(item) -> bool:
	if item is MTGAction:
		return _submit(item)
	return _submit_option(item)


func _submit(action: MTGAction) -> bool:
	var ok := human.submit(action)
	_after_submit(ok)
	return ok


func _submit_option(option: Dictionary) -> bool:
	var typed: Array[MTGAction] = []
	for action in option["sequence"]:
		typed.append(action)
	var ok := human.submit_sequence(typed)
	_after_submit(ok)
	return ok


func _after_submit(ok: bool) -> void:
	if ok:
		_set_mode(Mode.IDLE)
		hud.set_controls(false, "", false)
		hud.set_prompt("")
	else:
		hud.log_line("That move is not legal right now.", "#ff8a8a")


# ───────────────────────────── Option building ─────────────────────────────

## Every way to play a hand card right now. Lands: one option per "as it enters"
## choice. Spells: one option per target assignment × kicker, each preceded by the
## land taps needed to pay (the same TAP_LAND actions an AI would take).
func _play_options_for(card: CardInstance) -> Array:
	var result: Array = []
	var state := session.state
	var engine := session.engine
	if card.definition == null:
		return result

	if card.definition.is_land():
		for act in legal:
			if act.action_type == MTGAction.ActionType.PLAY_LAND and act.card_instance_id == card.instance_id:
				result.append({"sequence": [act], "final": act, "cost": {}})
		return result

	for cast in engine.get_cast_actions_for_card(state, 0, card, false):
		var cost := Costs.cast_cost(state, card, 0, cast.kicked)
		var option := _option_with_taps(cast, cost)
		if not option.is_empty():
			if cast.kicked:
				cast.label = "Cast kicked"
			elif card.definition.rules.has("kicker"):
				cast.label = "Cast"
			result.append(option)
	return result


## Activated abilities of a permanent the player could pay for (with auto-tapping).
func _ability_options_for(card: CardInstance) -> Array:
	var result: Array = []
	var state := session.state
	var engine := session.engine
	for ability in engine.get_ability_actions(state, 0, card, false):
		var option := _option_with_taps(ability, engine.ability_cost(card, ability.ability_index))
		if not option.is_empty():
			result.append(option)
	return result


func _option_with_taps(final: MTGAction, cost: Dictionary) -> Dictionary:
	var state := session.state
	var sequence: Array = []
	if not state.players[0].has_mana_available(cost):
		var plan := Costs.plan_land_taps(state, 0, cost)
		if not plan["possible"]:
			return {}
		sequence.append_array(plan["actions"])
	sequence.append(final)
	return {"sequence": sequence, "final": final, "cost": cost}


# ───────────────────────────── Helpers ─────────────────────────────

func _location(instance_id: int) -> Dictionary:
	return session.state.find_card_location(instance_id)


func _has_action(type: MTGAction.ActionType) -> bool:
	for action in legal:
		if action.action_type == type:
			return true
	return false


func _eligible_attackers() -> Array[int]:
	var ids: Array[int] = []
	for action in legal:
		if action.action_type == MTGAction.ActionType.DECLARE_ATTACKERS:
			for id in action.attacker_ids:
				if id not in ids:
					ids.append(id)
	return ids


func _blocker_candidates() -> Array[int]:
	var ids: Array[int] = []
	for action in legal:
		if action.action_type == MTGAction.ActionType.DECLARE_BLOCKER and action.blocker_id not in ids:
			ids.append(action.blocker_id)
	return ids


func _attackers_blockable_by(blocker_id: int) -> Array[int]:
	var ids: Array[int] = []
	for action in legal:
		if action.action_type == MTGAction.ActionType.DECLARE_BLOCKER and action.blocker_id == blocker_id:
			ids.append(action.blocking_attacker_id)
	return ids
