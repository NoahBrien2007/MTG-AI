class_name MTGRulesEngine
extends RefCounted

## Pure, stateless rules engine. get_legal_actions() enumerates every decision
## the acting player may take; apply_action() returns the resulting state.
## Both humans and AI agents are limited to exactly this action set.
##
## Card-specific behaviour is never hard-coded here: it comes from the card's
## script (CardLibrary / OracleParser) and is executed by Effects, Targeting,
## Triggers, Conditions and Costs.

## Above this many eligible attackers we stop enumerating every subset
## (2^n actions) and only offer none / all / each single attacker.
const MAX_ATTACK_SUBSET_ENUMERATION := 5

const BASIC_LAND_TYPES := ["Plains", "Island", "Swamp", "Mountain", "Forest"]


# ───────────────────────────── Legal actions ─────────────────────────────

func get_legal_actions(state: MTGGameState) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []
	if state.game_over:
		return actions

	# A pending effect decision pre-empts everything else.
	if state.has_pending_choice():
		var pending := state.pending_choice
		for i in range(pending["options"].size()):
			var act := MTGAction.new(MTGAction.ActionType.CHOOSE, pending["player"])
			act.choice_index = i
			act.label = pending["options"][i].get("label", "Option %d" % (i + 1))
			actions.append(act)
		return actions

	var player_id := state.priority_player
	var player := state.players[player_id]

	if state.current_step == MTGGameState.Step.DECLARE_ATTACKERS and player_id == state.active_player:
		return _get_attacker_actions(state, player_id)

	if state.current_step == MTGGameState.Step.DECLARE_BLOCKERS and player_id != state.active_player:
		return _get_blocker_actions(state, player_id)

	actions.append(MTGAction.new(MTGAction.ActionType.PASS_PRIORITY, player_id))

	# Mana abilities
	for source in Costs.mana_sources(state, player_id):
		for color in source["colors"]:
			var act := MTGAction.new(MTGAction.ActionType.TAP_LAND, player_id)
			act.card_instance_id = source["card"].instance_id
			act.mana_color = color
			actions.append(act)

	# Play a land (one action per "as it enters" choice combination)
	if can_play_land(state, player_id):
		for card in player.hand:
			if card.definition and card.definition.is_land():
				actions.append_array(get_play_land_actions(state, player_id, card))

	# Cast spells
	for card in player.hand:
		if card.definition and not card.definition.is_land():
			actions.append_array(get_cast_actions_for_card(state, player_id, card, true))

	# Activated abilities of permanents
	for card in player.battlefield:
		actions.append_array(get_ability_actions(state, player_id, card, true))

	return actions


## True if `action` may be applied to `state` right now.
func is_action_legal(state: MTGGameState, action: MTGAction) -> bool:
	if action == null or state.game_over or action.player_id != state.acting_player():
		return false

	# Attack declarations are validated structurally so any subset of eligible
	# attackers is accepted, even when not every subset was enumerated.
	if action.action_type == MTGAction.ActionType.DECLARE_ATTACKERS:
		if state.has_pending_choice() or state.current_step != MTGGameState.Step.DECLARE_ATTACKERS \
				or action.player_id != state.active_player:
			return false
		for att_id in action.attacker_ids:
			var card := _battlefield_card(state, att_id)
			if card == null or card.controller_id != action.player_id or not card.can_attack():
				return false
		return true

	var wanted := action.signature()
	for legal in get_legal_actions(state):
		if legal.signature() == wanted:
			return true
	return false


func can_play_land(state: MTGGameState, player_id: int) -> bool:
	return state.is_main_phase() \
		and state.stack.is_empty() \
		and not state.land_played_this_turn \
		and player_id == state.active_player \
		and player_id == state.priority_player


## All PLAY_LAND variants for a land card (replacement choices become options).
func get_play_land_actions(state: MTGGameState, player_id: int, card: CardInstance) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []
	var choices: Array = card.definition.rules.get("enter_choices", [])
	var variants: Array = [{}]
	for choice in choices:
		var next: Array = []
		for base in variants:
			match choice:
				"choose_basic_land_type":
					for land_type in BASIC_LAND_TYPES:
						var v: Dictionary = base.duplicate()
						v["land_type"] = land_type
						next.append(v)
				"pay_2_life_or_tapped":
					var pay: Dictionary = base.duplicate()
					pay["pay_life"] = true
					var no_pay: Dictionary = base.duplicate()
					no_pay["pay_life"] = false
					if state.players[player_id].life > 2:
						next.append(pay)
					next.append(no_pay)
				_:
					next.append(base)
		variants = next

	for options in variants:
		var act := MTGAction.new(MTGAction.ActionType.PLAY_LAND, player_id)
		act.card_instance_id = card.instance_id
		act.options = options
		var parts: PackedStringArray = []
		if options.has("land_type"):
			parts.append(options["land_type"])
		if options.has("pay_life"):
			parts.append("pay 2 life, untapped" if options["pay_life"] else "enters tapped")
		act.label = ", ".join(parts)
		actions.append(act)
	return actions


## Sorcery-speed spells need: own turn, main phase, empty stack. Instants (and
## flash) any time you hold priority.
func is_cast_timing_legal(state: MTGGameState, player_id: int, card: CardInstance) -> bool:
	if not card.definition or card.definition.is_land():
		return false
	if state.priority_player != player_id or state.has_pending_choice():
		return false
	if card.definition.card_type == CardDefinition.CardType.INSTANT or card.definition.has_keyword("flash"):
		return true
	return state.is_main_phase() and state.stack.is_empty() and player_id == state.active_player


## Every CAST_SPELL variant (targets × kicker) for a card. With
## `require_mana` only variants the player can pay for right now are returned.
func get_cast_actions_for_card(state: MTGGameState, player_id: int, card: CardInstance, require_mana: bool = false) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []
	if not is_cast_timing_legal(state, player_id, card):
		return actions
	var rules := card.definition.rules
	var player := state.players[player_id]

	var kick_variants: Array[bool] = [false]
	if rules.has("kicker"):
		kick_variants.append(true)

	var assignments := Targeting.enumerate(state, rules.get("targets", []), player_id, card)
	if assignments.is_empty():
		return actions

	for kicked in kick_variants:
		if require_mana and not player.has_mana_available(Costs.cast_cost(state, card, player_id, kicked)):
			continue
		for slots in assignments:
			var act := MTGAction.new(MTGAction.ActionType.CAST_SPELL, player_id)
			act.card_instance_id = card.instance_id
			act.kicked = kicked
			var typed_slots: Array[Dictionary] = []
			for slot in slots:
				typed_slots.append(slot)
			act.targets = typed_slots
			actions.append(act)
	return actions


## Activated abilities of a permanent the player controls.
func get_ability_actions(state: MTGGameState, player_id: int, card: CardInstance, require_mana: bool = false) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []
	if card.controller_id != player_id or card.definition == null or state.has_pending_choice():
		return actions
	var abilities: Array = card.definition.rules.get("abilities", [])
	for i in range(abilities.size()):
		var ability: Dictionary = abilities[i]
		if ability.get("sorcery_speed", false) and not (state.is_main_phase() and state.stack.is_empty() and player_id == state.active_player):
			continue
		if not Conditions.check(ability.get("condition", ""), state, card, player_id):
			continue
		var cost := CardDatabase.parse_mana_cost(ability.get("cost", ""))
		if require_mana and not state.players[player_id].has_mana_available(cost):
			continue
		var assignments := Targeting.enumerate(state, ability.get("targets", []), player_id, card)
		if assignments.is_empty():
			continue
		for slots in assignments:
			var act := MTGAction.new(MTGAction.ActionType.ACTIVATE_ABILITY, player_id)
			act.card_instance_id = card.instance_id
			act.ability_index = i
			act.label = "%s (%s)" % [ability.get("label", "Ability %d" % (i + 1)), Costs.to_text(cost)]
			var typed_slots: Array[Dictionary] = []
			for slot in slots:
				typed_slots.append(slot)
			act.targets = typed_slots
			actions.append(act)
	return actions


func ability_cost(card: CardInstance, ability_index: int) -> Dictionary:
	var abilities: Array = card.definition.rules.get("abilities", [])
	if ability_index < 0 or ability_index >= abilities.size():
		return {}
	return CardDatabase.parse_mana_cost(abilities[ability_index].get("cost", ""))


# ───────────────────────────── Apply ─────────────────────────────

func apply_action(state: MTGGameState, action: MTGAction) -> MTGGameState:
	var next_state := state.duplicate_state()
	if next_state.game_over:
		return next_state

	match action.action_type:
		MTGAction.ActionType.PASS_PRIORITY:
			_handle_pass_priority(next_state)
		MTGAction.ActionType.TAP_LAND:
			_handle_tap_land(next_state, action)
		MTGAction.ActionType.PLAY_LAND:
			_handle_play_land(next_state, action)
		MTGAction.ActionType.CAST_SPELL:
			_handle_cast_spell(next_state, action)
		MTGAction.ActionType.ACTIVATE_ABILITY:
			_handle_activate_ability(next_state, action)
		MTGAction.ActionType.DECLARE_ATTACKERS:
			_handle_declare_attackers(next_state, action)
		MTGAction.ActionType.DECLARE_BLOCKER:
			_handle_declare_blocker(next_state, action)
		MTGAction.ActionType.FINISH_COMBAT_DECLARATIONS:
			_handle_finish_combat_declarations(next_state)
		MTGAction.ActionType.CHOOSE:
			Effects.resume(next_state, action.choice_index)

	Effects.drain(next_state)
	check_state_based_actions(next_state)
	return next_state


# ───────────────────────────── Handlers ─────────────────────────────

func _handle_pass_priority(state: MTGGameState) -> void:
	state.consecutive_passes += 1
	if state.consecutive_passes >= 2:
		state.consecutive_passes = 0
		if not state.stack.is_empty():
			_resolve_top_of_stack(state)
			state.priority_player = state.active_player
		else:
			_clear_mana_pools(state)
			_advance_step(state)
	else:
		state.priority_player = state.get_opponent_id(state.priority_player)


func _handle_tap_land(state: MTGGameState, action: MTGAction) -> void:
	var card := _battlefield_card(state, action.card_instance_id)
	if card and not card.tapped:
		card.tapped = true
		state.players[action.player_id].add_mana(action.mana_color, 1)
	state.consecutive_passes = 0


func _handle_play_land(state: MTGGameState, action: MTGAction) -> void:
	var player := state.players[action.player_id]
	var card := _take_from_hand(player, action.card_instance_id)
	if card == null:
		return
	state.land_played_this_turn = true
	state.consecutive_passes = 0

	if action.options.has("land_type"):
		card.chosen_land_type = action.options["land_type"]
	var enters_tapped := false
	if action.options.has("pay_life"):
		if action.options["pay_life"]:
			player.life -= 2
		else:
			enters_tapped = true
	if card.definition.rules.has("enters_tapped") \
			and Conditions.check(card.definition.rules["enters_tapped"], state, card, action.player_id):
		enters_tapped = true
	_enter_battlefield(state, card, action.player_id, enters_tapped)


func _handle_cast_spell(state: MTGGameState, action: MTGAction) -> void:
	var player := state.players[action.player_id]
	var card := _take_from_hand(player, action.card_instance_id)
	if card == null:
		return
	player.spend_mana(Costs.cast_cost(state, card, action.player_id, action.kicked))
	state.stack.append({
		"card": card,
		"controller": action.player_id,
		"targets": action.targets.duplicate(true),
		"kicked": action.kicked,
	})
	state.consecutive_passes = 0
	Triggers.on_event(state, "cast_spell", {"player": action.player_id, "spell": card.instance_id})


func _handle_activate_ability(state: MTGGameState, action: MTGAction) -> void:
	var card := _battlefield_card(state, action.card_instance_id)
	if card == null:
		return
	var abilities: Array = card.definition.rules.get("abilities", [])
	if action.ability_index < 0 or action.ability_index >= abilities.size():
		return
	var ability: Dictionary = abilities[action.ability_index]
	state.players[action.player_id].spend_mana(ability_cost(card, action.ability_index))
	state.consecutive_passes = 0
	# Abilities resolve immediately (they don't use the stack).
	var ctx := Effects.make_context(card.instance_id, action.player_id, ability.get("effects", []), action.targets)
	Effects.run(state, ctx)


func _resolve_top_of_stack(state: MTGGameState) -> void:
	if state.stack.is_empty():
		return
	var item: Dictionary = state.stack[state.stack.size() - 1]
	var card: CardInstance = item["card"]
	var controller: int = item["controller"]

	if card.definition.is_permanent():
		state.stack.pop_back()
		var enters_tapped := Conditions.check(card.definition.rules.get("enters_tapped", ""), state, card, controller) \
			if card.definition.rules.has("enters_tapped") else false
		_enter_battlefield(state, card, controller, enters_tapped)
		return

	# Instant / sorcery: the card stays on the stack while its effects resolve
	# (a pending choice may interrupt) and goes to the graveyard when done.
	var ctx := Effects.make_context(card.instance_id, controller, card.definition.rules.get("spell", []), item["targets"], item["kicked"])
	ctx["on_complete"] = "spell_to_graveyard"
	Effects.run(state, ctx)


func _enter_battlefield(state: MTGGameState, card: CardInstance, controller: int, tapped: bool) -> void:
	card.controller_id = controller
	card.summoned_this_turn = true
	card.tapped = tapped
	if card.definition.has_subtype("Class") and card.class_level == 0:
		card.class_level = 1
	state.players[controller].battlefield.append(card)
	Triggers.on_event(state, "etb", {"card": card.instance_id})


func _handle_declare_attackers(state: MTGGameState, action: MTGAction) -> void:
	state.declared_attackers.clear()
	for att_id in action.attacker_ids:
		var card := _battlefield_card(state, att_id)
		if card and card.controller_id == action.player_id and card.can_attack():
			card.tapped = true
			state.declared_attackers.append(att_id)

	if state.declared_attackers.is_empty():
		state.current_phase = MTGGameState.Phase.COMBAT
		state.current_step = MTGGameState.Step.END_COMBAT
		_advance_step(state)
	else:
		state.current_step = MTGGameState.Step.DECLARE_BLOCKERS
		state.priority_player = state.get_opponent_id(action.player_id)


func _handle_declare_blocker(state: MTGGameState, action: MTGAction) -> void:
	state.declared_blockers[action.blocker_id] = action.blocking_attacker_id


func _handle_finish_combat_declarations(state: MTGGameState) -> void:
	state.current_step = MTGGameState.Step.COMBAT_DAMAGE
	_resolve_combat_damage(state)
	state.current_step = MTGGameState.Step.END_COMBAT
	_advance_step(state)


func _resolve_combat_damage(state: MTGGameState) -> void:
	var defender := state.players[state.get_opponent_id(state.active_player)]

	var attacker_blockers: Dictionary = {}
	for att_id in state.declared_attackers:
		attacker_blockers[att_id] = []
	for blocker_id in state.declared_blockers.keys():
		var att_id: int = state.declared_blockers[blocker_id]
		if attacker_blockers.has(att_id):
			attacker_blockers[att_id].append(blocker_id)

	for att_id in state.declared_attackers:
		var attacker := _battlefield_card(state, att_id)
		if attacker == null:
			continue
		var blockers: Array = attacker_blockers.get(att_id, [])
		if blockers.is_empty():
			defender.life -= attacker.get_power()
		else:
			for b_id in blockers:
				var blocker := _battlefield_card(state, b_id)
				if blocker:
					blocker.damage_marked += attacker.get_power()
					attacker.damage_marked += blocker.get_power()


# ───────────────────────────── Turn structure ─────────────────────────────

func _advance_step(state: MTGGameState) -> void:
	match state.current_step:
		MTGGameState.Step.UNTAP:
			_execute_untap_step(state)
			state.current_step = MTGGameState.Step.UPKEEP
		MTGGameState.Step.UPKEEP:
			state.current_step = MTGGameState.Step.DRAW
			state.players[state.active_player].draw_card()
		MTGGameState.Step.DRAW:
			state.current_phase = MTGGameState.Phase.PRECOMBAT_MAIN
			state.current_step = MTGGameState.Step.MAIN_1
		MTGGameState.Step.MAIN_1:
			state.current_phase = MTGGameState.Phase.COMBAT
			state.current_step = MTGGameState.Step.BEGIN_COMBAT
		MTGGameState.Step.BEGIN_COMBAT:
			state.current_step = MTGGameState.Step.DECLARE_ATTACKERS
		MTGGameState.Step.END_COMBAT:
			state.current_phase = MTGGameState.Phase.POSTCOMBAT_MAIN
			state.current_step = MTGGameState.Step.MAIN_2
			state.declared_attackers.clear()
			state.declared_blockers.clear()
		MTGGameState.Step.MAIN_2:
			state.current_phase = MTGGameState.Phase.ENDING
			state.current_step = MTGGameState.Step.END_STEP
			Triggers.on_event(state, "end_step", {"player": state.active_player})
		MTGGameState.Step.END_STEP:
			state.current_step = MTGGameState.Step.CLEANUP
			_execute_cleanup_step(state)
	state.priority_player = state.active_player


func _execute_untap_step(state: MTGGameState) -> void:
	for card in state.players[state.active_player].battlefield:
		card.tapped = false
		card.summoned_this_turn = false
		card.is_land_until_next_turn = false # "until your next turn" ends here


func _execute_cleanup_step(state: MTGGameState) -> void:
	for player in state.players:
		player.reset_mana_pool()
		for card in player.battlefield:
			card.clear_until_end_of_turn()

	# Next turn
	state.turn_number += 1
	state.active_player = state.get_opponent_id(state.active_player)
	state.land_played_this_turn = false
	state.consecutive_passes = 0
	state.current_phase = MTGGameState.Phase.BEGINNING
	state.current_step = MTGGameState.Step.UNTAP
	_execute_untap_step(state)


func _clear_mana_pools(state: MTGGameState) -> void:
	for player in state.players:
		player.reset_mana_pool()


# ───────────────────────────── Combat helpers ─────────────────────────────

func _get_attacker_actions(state: MTGGameState, player_id: int) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []
	var eligible: Array[int] = []
	for card in state.players[player_id].battlefield:
		if card.can_attack():
			eligible.append(card.instance_id)

	actions.append(MTGAction.new(MTGAction.ActionType.DECLARE_ATTACKERS, player_id))
	if eligible.is_empty():
		return actions

	if eligible.size() <= MAX_ATTACK_SUBSET_ENUMERATION:
		for mask in range(1, 1 << eligible.size()):
			var act := MTGAction.new(MTGAction.ActionType.DECLARE_ATTACKERS, player_id)
			for i in range(eligible.size()):
				if mask & (1 << i):
					act.attacker_ids.append(eligible[i])
			actions.append(act)
	else:
		var all_attack := MTGAction.new(MTGAction.ActionType.DECLARE_ATTACKERS, player_id)
		all_attack.attacker_ids = eligible.duplicate()
		actions.append(all_attack)
		for att_id in eligible:
			var single := MTGAction.new(MTGAction.ActionType.DECLARE_ATTACKERS, player_id)
			single.attacker_ids = [att_id]
			actions.append(single)
	return actions


func _get_blocker_actions(state: MTGGameState, player_id: int) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []
	actions.append(MTGAction.new(MTGAction.ActionType.FINISH_COMBAT_DECLARATIONS, player_id))
	if state.declared_attackers.is_empty():
		return actions

	for card in state.players[player_id].battlefield:
		if state.declared_blockers.has(card.instance_id):
			continue
		for att_id in state.declared_attackers:
			var attacker := _battlefield_card(state, att_id)
			if attacker == null or not card.can_block(attacker):
				continue
			var act := MTGAction.new(MTGAction.ActionType.DECLARE_BLOCKER, player_id)
			act.blocker_id = card.instance_id
			act.blocking_attacker_id = att_id
			actions.append(act)
	return actions


# ───────────────────────────── State-based actions ─────────────────────────────

func check_state_based_actions(state: MTGGameState) -> void:
	if state.game_over:
		return

	var p0 := state.players[0]
	var p1 := state.players[1]
	if p0.life <= 0:
		p0.has_lost = true
	if p1.life <= 0:
		p1.has_lost = true

	if p0.has_lost and p1.has_lost:
		state.game_over = true
		state.winner_id = -1
		return
	elif p0.has_lost:
		state.game_over = true
		state.winner_id = 1
		return
	elif p1.has_lost:
		state.game_over = true
		state.winner_id = 0
		return

	# Creatures with lethal damage or 0 toughness die
	for player in state.players:
		for i in range(player.battlefield.size() - 1, -1, -1):
			var card := player.battlefield[i]
			if card.is_creature() and (card.damage_marked >= card.get_toughness() or card.get_toughness() <= 0):
				player.battlefield.remove_at(i)
				if not card.definition.is_token:
					state.players[card.owner_id].graveyard.append(card)


# ───────────────────────────── Lookups ─────────────────────────────

func _battlefield_card(state: MTGGameState, card_id: int) -> CardInstance:
	for p in state.players:
		for card in p.battlefield:
			if card.instance_id == card_id:
				return card
	return null


func _take_from_hand(player: MTGPlayer, card_id: int) -> CardInstance:
	for i in range(player.hand.size()):
		if player.hand[i].instance_id == card_id:
			var card := player.hand[i]
			player.hand.remove_at(i)
			return card
	return null
