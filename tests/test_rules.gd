extends SceneTree

## Headless engine tests. Run from the project folder with:
##   godot --headless -s tests/test_rules.gd

const DECK := "res://data/decks/botboys_deck_izzet.txt"

var _engine := MTGRulesEngine.new()


func _init() -> void:
	print("--- Running MTG Engine Unit Tests ---")
	test_deck_loader()
	test_deep_clone()
	test_mana_cost_parsing()
	test_mana_and_land_play()
	test_combat_and_sba()
	test_action_validation()
	test_burst_lightning_kicker()
	test_spell_pierce()
	test_opt_scry_and_draw()
	test_steam_vents_choices()
	test_eddymurk_crab()
	test_stormchaser_talent()
	test_boomerang_basics_and_flying()
	test_state_encoder()
	run_ai_simulation()
	print("--- ALL TESTS AND SIMULATIONS COMPLETED SUCCESSFULLY! ---")
	quit(0)


# ───────────────────────────── Helpers ─────────────────────────────

func _new_session() -> GameSession:
	var session := GameSession.new()
	session.setup(DECK, DECK, HeuristicAgent.new(0), HeuristicAgent.new(1), 12345)
	return session


func _card(state: MTGGameState, card_name: String, owner: int) -> CardInstance:
	var c := CardInstance.new(state.next_instance_id, CardDatabase.get_card_definition(card_name), owner)
	state.next_instance_id += 1
	return c


func _to_hand(state: MTGGameState, card_name: String, owner: int) -> CardInstance:
	var c := _card(state, card_name, owner)
	state.players[owner].hand.append(c)
	return c


func _to_battlefield(state: MTGGameState, card_name: String, owner: int, sick: bool = false) -> CardInstance:
	var c := _card(state, card_name, owner)
	c.summoned_this_turn = sick
	if c.definition.has_subtype("Class"):
		c.class_level = 1
	state.players[owner].battlefield.append(c)
	return c


func _main_phase(state: MTGGameState, player: int) -> void:
	state.active_player = player
	state.priority_player = player
	state.current_phase = MTGGameState.Phase.PRECOMBAT_MAIN
	state.current_step = MTGGameState.Step.MAIN_1
	state.stack.clear()


func _find(actions: Array[MTGAction], type: MTGAction.ActionType, card_id: int = -1) -> MTGAction:
	for a in actions:
		if a.action_type == type and (card_id == -1 or a.card_instance_id == card_id):
			return a
	return null


func _pass_both(state: MTGGameState) -> MTGGameState:
	state = _engine.apply_action(state, MTGAction.new(MTGAction.ActionType.PASS_PRIORITY, state.priority_player))
	return _engine.apply_action(state, MTGAction.new(MTGAction.ActionType.PASS_PRIORITY, state.priority_player))


# ───────────────────────────── Core ─────────────────────────────

func test_deck_loader() -> void:
	print("[Test] Loading 60-card deck...")
	var state := MTGGameState.new()
	var deck := DeckLoader.load_deck_from_file(DECK, 0, state)
	assert(deck.size() == 60, "Expected 60 cards in the deck!")
	var opt := CardDatabase.get_card_definition("Opt")
	assert(opt.card_type == CardDefinition.CardType.INSTANT, "Opt should be an instant (cards.json loaded?)")
	assert(not opt.rules.is_empty(), "Opt should have a rules script")
	print(" -> 60 cards loaded, definitions have scripts.")


func test_deep_clone() -> void:
	print("[Test] Deep state cloning...")
	var state1 := _new_session().state
	var state2 := state1.duplicate_state()
	state2.players[0].life = 5
	state2.turn_number = 10
	assert(state1.players[0].life == 20 and state1.turn_number == 1, "Clone mutated the original!")
	print(" -> Clone isolated.")


func test_mana_cost_parsing() -> void:
	print("[Test] Mana cost parsing & payment...")
	var cost := CardDatabase.parse_mana_cost("{2}{U}{R}")
	assert(cost.get("generic", 0) == 2 and cost.get("U", 0) == 1 and cost.get("R", 0) == 1, "Bad cost parse!")
	var player := MTGPlayer.new(0)
	player.add_mana("U", 1)
	player.add_mana("R", 1)
	player.add_mana("G", 2)
	assert(player.has_mana_available(cost), "Should afford {2}{U}{R} with U R G G!")
	assert(player.spend_mana(cost) and player.total_mana() == 0, "Payment failed!")
	print(" -> Generic + coloured payment verified.")


func test_mana_and_land_play() -> void:
	print("[Test] Land play & mana tapping...")
	var session := _new_session()
	var state := session.state
	var island := _to_hand(state, "Island", 0)
	var play := _find(_engine.get_legal_actions(state), MTGAction.ActionType.PLAY_LAND, island.instance_id)
	assert(play != null, "Should be able to play Island!")
	state = _engine.apply_action(state, play)
	assert(state.land_played_this_turn, "Land should be marked as played!")
	var tap := _find(_engine.get_legal_actions(state), MTGAction.ActionType.TAP_LAND, island.instance_id)
	assert(tap != null and tap.mana_color == "U", "Island should tap for U!")
	state = _engine.apply_action(state, tap)
	assert(state.players[0].mana_pool["U"] == 1, "Tapping Island should give one blue!")
	print(" -> Verified.")


func test_combat_and_sba() -> void:
	print("[Test] Combat & state-based actions...")
	var state := _new_session().state
	var attacker := _to_battlefield(state, "Eddymurk Crab", 0)   # 5/5
	var blocker := _to_battlefield(state, "Slickshot Show-Off", 1) # 1/2 flying
	state.current_step = MTGGameState.Step.DECLARE_ATTACKERS
	state.current_phase = MTGGameState.Phase.COMBAT
	_main_phase_players(state, 0)

	var attack := MTGAction.new(MTGAction.ActionType.DECLARE_ATTACKERS, 0)
	attack.attacker_ids = [attacker.instance_id]
	assert(_engine.is_action_legal(state, attack), "Attack should be legal!")
	state = _engine.apply_action(state, attack)
	assert(state.current_step == MTGGameState.Step.DECLARE_BLOCKERS, "Should be declaring blockers!")

	var block := MTGAction.new(MTGAction.ActionType.DECLARE_BLOCKER, 1)
	block.blocker_id = blocker.instance_id
	block.blocking_attacker_id = attacker.instance_id
	assert(_engine.is_action_legal(state, block), "Flier can block a ground creature!")
	state = _engine.apply_action(state, block)
	state = _engine.apply_action(state, MTGAction.new(MTGAction.ActionType.FINISH_COMBAT_DECLARATIONS, 1))
	assert(state.players[1].graveyard.size() == 1, "Blocker should die!")
	assert(state.players[0].battlefield.size() == 1, "Crab should survive!")
	print(" -> Verified.")


func _main_phase_players(state: MTGGameState, active: int) -> void:
	state.active_player = active
	state.priority_player = active


func test_action_validation() -> void:
	print("[Test] Action validation...")
	var session := _new_session()
	var bogus := MTGAction.new(MTGAction.ActionType.CAST_SPELL, 0)
	bogus.card_instance_id = 9999
	assert(not session.apply(bogus), "Casting a non-existent card must be rejected!")
	assert(not session.apply(MTGAction.new(MTGAction.ActionType.PASS_PRIORITY, 1)), "Acting without priority must be rejected!")
	assert(session.apply(MTGAction.new(MTGAction.ActionType.PASS_PRIORITY, 0)), "Passing must be legal!")
	print(" -> Verified.")


# ───────────────────────────── Cards ─────────────────────────────

func test_burst_lightning_kicker() -> void:
	print("[Test] Burst Lightning (kicker, any target)...")
	var state := _new_session().state
	_main_phase(state, 0)
	var bolt := _to_hand(state, "Burst Lightning", 0)
	state.players[0].add_mana("R", 1)
	state.players[0].add_mana("U", 4)

	var actions := _engine.get_legal_actions(state)
	var normal: MTGAction = null
	var kicked: MTGAction = null
	for a in actions:
		if a.action_type == MTGAction.ActionType.CAST_SPELL and a.card_instance_id == bolt.instance_id and a.target_player() == 1:
			if a.kicked:
				kicked = a
			else:
				normal = a
	assert(normal != null and kicked != null, "Both normal and kicked casts should be offered!")

	state = _engine.apply_action(state, kicked)
	assert(state.stack.size() == 1 and state.players[0].total_mana() == 0, "Kicked bolt should cost all 5 mana!")
	state = _pass_both(state)
	assert(state.players[1].life == 16, "Kicked Burst Lightning should deal 4 (life %d)!" % state.players[1].life)
	assert(state.players[0].graveyard.size() == 1, "Bolt should be in the graveyard!")
	print(" -> Verified.")


func test_spell_pierce() -> void:
	print("[Test] Spell Pierce (counter unless pays {2})...")
	var state := _new_session().state
	_main_phase(state, 0)
	var opt := _to_hand(state, "Opt", 0)
	var pierce := _to_hand(state, "Spell Pierce", 1)
	state.players[0].add_mana("U", 1)
	state.players[1].add_mana("U", 1)

	state = _engine.apply_action(state, _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, opt.instance_id))
	state = _engine.apply_action(state, MTGAction.new(MTGAction.ActionType.PASS_PRIORITY, 0))
	assert(state.priority_player == 1, "Opponent should get priority with Opt on the stack!")
	var counter := _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, pierce.instance_id)
	assert(counter != null and counter.target_card() == opt.instance_id, "Spell Pierce should target Opt on the stack!")
	state = _engine.apply_action(state, counter)
	assert(state.stack.size() == 2, "Two spells on the stack!")
	# Resolve Spell Pierce: P0 has no mana → countered outright.
	state = _pass_both(state)
	assert(state.stack.is_empty(), "Opt should have been countered (stack %d)!" % state.stack.size())
	assert(state.players[0].graveyard.size() == 1 and state.players[1].graveyard.size() == 1, "Both spells in graveyards!")
	print(" -> Verified.")


func test_opt_scry_and_draw() -> void:
	print("[Test] Opt (scry 1, draw) with pending choice...")
	var state := _new_session().state
	_main_phase(state, 0)
	var opt := _to_hand(state, "Opt", 0)
	state.players[0].add_mana("U", 1)
	var hand_before := state.players[0].hand.size()
	var top_id: int = state.players[0].library[state.players[0].library.size() - 1].instance_id

	state = _engine.apply_action(state, _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, opt.instance_id))
	state = _pass_both(state)
	assert(state.has_pending_choice() and state.pending_choice["kind"] == "scry", "Opt should ask to scry!")
	var choices := _engine.get_legal_actions(state)
	assert(choices.size() == 2 and choices[0].action_type == MTGAction.ActionType.CHOOSE, "Two scry options expected!")
	state = _engine.apply_action(state, choices[1]) # bottom
	assert(not state.has_pending_choice(), "Choice resolved!")
	assert(state.players[0].hand.size() == hand_before, "Cast Opt (-1) then drew (+1)!")
	assert(state.players[0].library[0].instance_id == top_id, "Scryed card should be on the bottom!")
	print(" -> Verified.")


func test_steam_vents_choices() -> void:
	print("[Test] Steam Vents (pay 2 life or tapped) & Multiversal Passage...")
	var state := _new_session().state
	_main_phase(state, 0)
	var vents := _to_hand(state, "Steam Vents", 0)
	var plays: Array[MTGAction] = []
	for a in _engine.get_legal_actions(state):
		if a.action_type == MTGAction.ActionType.PLAY_LAND and a.card_instance_id == vents.instance_id:
			plays.append(a)
	assert(plays.size() == 2, "Steam Vents should offer pay/tapped (%d)!" % plays.size())
	var pay: MTGAction = plays[0] if plays[0].options["pay_life"] else plays[1]
	state = _engine.apply_action(state, pay)
	assert(state.players[0].life == 18, "Paid 2 life!")
	var vents_bf := state.find_card_instance(vents.instance_id)
	assert(not vents_bf.tapped and vents_bf.has_subtype("Island"), "Untapped Island Mountain!")

	state.land_played_this_turn = false
	var passage := _to_hand(state, "Multiversal Passage", 0)
	var count := 0
	var chosen: MTGAction = null
	for a in _engine.get_legal_actions(state):
		if a.action_type == MTGAction.ActionType.PLAY_LAND and a.card_instance_id == passage.instance_id:
			count += 1
			if a.options.get("land_type", "") == "Mountain" and not a.options["pay_life"]:
				chosen = a
	assert(count == 10, "Passage: 5 types × pay/tapped = 10 variants (%d)!" % count)
	state = _engine.apply_action(state, chosen)
	var passage_bf := state.find_card_instance(passage.instance_id)
	assert(passage_bf.tapped and passage_bf.mana_abilities()[0]["color"] == "R", "Tapped Mountain that taps for R!")
	print(" -> Verified.")


func test_eddymurk_crab() -> void:
	print("[Test] Eddymurk Crab (cost reduction, flash, ETB tap)...")
	var state := _new_session().state
	_main_phase(state, 0)
	var crab := _to_hand(state, "Eddymurk Crab", 0)
	state.players[0].graveyard.append(_card(state, "Opt", 0))
	state.players[0].graveyard.append(_card(state, "Sleight of Hand", 0))
	var cost := Costs.cast_cost(state, crab, 0, false)
	assert(cost.get("generic", 0) == 3 and cost.get("U", 0) == 2, "Crab should cost {3}{U}{U} with two spells in graveyard!")

	var target1 := _to_battlefield(state, "Slickshot Show-Off", 1)
	var target2 := _to_battlefield(state, "Slickshot Show-Off", 1)
	state.players[0].add_mana("U", 5)
	state = _engine.apply_action(state, _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, crab.instance_id))
	state = _pass_both(state)
	assert(state.has_pending_choice() and state.pending_choice["kind"] == "targets", "Crab ETB should ask for targets!")
	var best: MTGAction = null
	for a in _engine.get_legal_actions(state):
		if state.pending_choice["options"][a.choice_index]["slots"].size() == 2:
			best = a
	state = _engine.apply_action(state, best)
	assert(state.find_card_instance(target1.instance_id).tapped and state.find_card_instance(target2.instance_id).tapped, "Both creatures tapped!")
	var crab_bf := state.find_card_instance(crab.instance_id)
	assert(crab_bf != null and not crab_bf.tapped, "Crab enters untapped on your own turn!")

	# Flash: castable on the opponent's turn
	var state2 := _new_session().state
	_main_phase(state2, 1)
	var crab2 := _to_hand(state2, "Eddymurk Crab", 0)
	state2.priority_player = 0
	state2.players[0].add_mana("U", 7)
	assert(_find(_engine.get_legal_actions(state2), MTGAction.ActionType.CAST_SPELL, crab2.instance_id) != null, "Flash lets Crab be cast on the opponent's turn!")
	print(" -> Verified.")


func test_stormchaser_talent() -> void:
	print("[Test] Stormchaser's Talent (token, levels, prowess)...")
	var state := _new_session().state
	_main_phase(state, 0)
	var talent := _to_hand(state, "Stormchaser's Talent", 0)
	state.players[0].add_mana("U", 1)
	state = _engine.apply_action(state, _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, talent.instance_id))
	state = _pass_both(state)
	var otters := 0
	for c in state.players[0].battlefield:
		if c.definition.is_token:
			otters += 1
			assert(c.has_keyword("prowess"), "Otter has prowess!")
	assert(otters == 1, "Talent ETB should create one Otter!")

	# Prowess: cast a noncreature spell → otter gets +1/+1
	var opt := _to_hand(state, "Opt", 0)
	state.players[0].add_mana("U", 1)
	state = _engine.apply_action(state, _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, opt.instance_id))
	for c in state.players[0].battlefield:
		if c.definition.is_token:
			assert(c.get_power() == 2, "Prowess should pump the Otter!")

	# Level 2: return an instant/sorcery from graveyard
	var opt_card := state.find_card_instance(opt.instance_id)
	state.stack.clear()
	state.players[0].graveyard.append(opt_card)
	state.players[0].add_mana("U", 4)
	var level := _find(_engine.get_legal_actions(state), MTGAction.ActionType.ACTIVATE_ABILITY, talent.instance_id)
	assert(level != null and level.ability_index == 0, "Level 2 ability should be available!")
	var hand_before := state.players[0].hand.size()
	state = _engine.apply_action(state, level)
	assert(state.has_pending_choice() and state.pending_choice["kind"] == "targets", "Level 2 should ask which card to return!")
	for a in _engine.get_legal_actions(state):
		if not state.pending_choice["options"][a.choice_index]["slots"].is_empty():
			state = _engine.apply_action(state, a)
			break
	var talent_bf := state.find_card_instance(talent.instance_id)
	assert(talent_bf.class_level == 2, "Class should be level 2!")
	assert(state.players[0].hand.size() == hand_before + 1, "Level 2 returns a spell to hand!")
	print(" -> Verified.")


func test_boomerang_basics_and_flying() -> void:
	print("[Test] Boomerang Basics (bounce) & flying blocks...")
	var state := _new_session().state
	_main_phase(state, 0)
	var boomerang := _to_hand(state, "Boomerang Basics", 0)
	var bird := _to_battlefield(state, "Slickshot Show-Off", 1)
	state.players[0].add_mana("U", 1)
	var cast := _find(_engine.get_legal_actions(state), MTGAction.ActionType.CAST_SPELL, boomerang.instance_id)
	assert(cast != null and cast.target_card() == bird.instance_id, "Boomerang should target the bird!")
	state = _engine.apply_action(state, cast)
	state = _pass_both(state)
	assert(state.players[1].battlefield.is_empty() and state.players[1].hand.size() == 8, "Bird bounced to hand!")

	var flyer := CardInstance.new(900, CardDatabase.get_card_definition("Slickshot Show-Off"), 0)
	var crab := CardInstance.new(901, CardDatabase.get_card_definition("Eddymurk Crab"), 1)
	assert(not crab.can_block(flyer), "Ground creature can't block a flier!")
	assert(flyer.can_block(crab), "Flier can block a ground creature!")
	print(" -> Verified.")


func test_state_encoder() -> void:
	print("[Test] State encoder...")
	var state := _new_session().state
	var encoded := StateEncoder.encode(state, 0)
	assert(encoded["features"].size() == StateEncoder.feature_count(), "Feature vector length mismatch (%d vs %d)!" % [encoded["features"].size(), StateEncoder.feature_count()])
	assert(encoded["card_ids"].size() == StateEncoder.total_slots(), "Card id vector length mismatch!")
	print(" -> %d features, %d card slots." % [encoded["features"].size(), encoded["card_ids"].size()])


func run_ai_simulation() -> void:
	print("[Test] AI self-play simulation...")
	var recorder := GameRecorder.new()
	var results := MatchRunner.new_results()
	for i in range(3):
		var final_state := MatchRunner.play_game(HeuristicAgent.new(0), GreedyAgent.new(1), DECK, DECK, 3000, recorder, 100 + i)
		MatchRunner.record_result(results, final_state)
	print(MatchRunner.summary_text(results, "Heuristic", "Greedy"))
	assert(recorder.games_recorded == 3 and not recorder.samples.is_empty(), "Recorder should have captured decisions!")
	print(" -> Recorded %d decisions." % recorder.samples.size())
