class_name GameSession
extends RefCounted

## Owns one game: the state, the rules engine and the two agents (human or AI).
## The loop is agent-agnostic — every player, human or AI, is asked for a legal
## MTGAction through BaseAgent.choose_action() and nothing else.

signal action_applied(action: MTGAction, description: String, state: MTGGameState)
## Emitted before an action is applied: the state the agent saw, the legal list
## and the index of the action it picked (training data hook).
signal decision_made(state: MTGGameState, legal: Array[MTGAction], chosen: int)
signal finished(state: MTGGameState)

const DEFAULT_DECK := "res://data/decks/botboys_deck_izzet.txt"
const OPENING_HAND_SIZE := 7

var engine := MTGRulesEngine.new()
var state: MTGGameState
var agents: Array[BaseAgent] = []

var max_actions: int = 4000
var actions_taken: int = 0

var _aborted: bool = false


## `rng_seed` makes the shuffles reproducible (0 = random). Everything after setup is
## deterministic given the action sequence, which training pipelines rely on.
## `first_player` is who is on the play; alternate it across a series, otherwise
## one seat carries the first-player advantage in every single game.
func setup(
	deck0_path: String,
	deck1_path: String,
	agent0: BaseAgent = null,
	agent1: BaseAgent = null,
	rng_seed: int = 0,
	first_player: int = 0
) -> void:
	state = MTGGameState.new()
	var rng := RandomNumberGenerator.new()
	if rng_seed != 0:
		rng.seed = rng_seed
	else:
		rng.randomize()
	var p0 := MTGPlayer.new(0)
	var p1 := MTGPlayer.new(1)
	state.players = [p0, p1]

	p0.library = DeckLoader.load_deck_from_file(deck0_path, 0, state)
	p1.library = DeckLoader.load_deck_from_file(deck1_path, 1, state)
	_shuffle(p0.library, rng)
	_shuffle(p1.library, rng)

	for i in range(OPENING_HAND_SIZE):
		p0.draw_card()
		p1.draw_card()

	state.turn_number = 1
	state.starting_player = first_player
	state.active_player = first_player
	state.priority_player = first_player
	state.current_phase = MTGGameState.Phase.PRECOMBAT_MAIN
	state.current_step = MTGGameState.Step.MAIN_1

	agents.clear()
	agents.append(agent0)
	agents.append(agent1)
	if agent0:
		agent0.player_id = 0
	if agent1:
		agent1.player_id = 1

	actions_taken = 0
	_aborted = false


static func _shuffle(cards: Array[CardInstance], rng: RandomNumberGenerator) -> void:
	for i in range(cards.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := cards[i]
		cards[i] = cards[j]
		cards[j] = tmp


func current_agent() -> BaseAgent:
	return agents[state.acting_player()]


func legal_actions() -> Array[MTGAction]:
	return engine.get_legal_actions(state)


## Validates and applies one action. Returns false if the action is illegal.
func apply(action: MTGAction, validate: bool = true) -> bool:
	if validate and not engine.is_action_legal(state, action):
		push_warning("GameSession: illegal action rejected: %s" % str(action))
		return false
	var description := action.describe(state)
	state = engine.apply_action(state, action)
	actions_taken += 1
	action_applied.emit(action, description, state)
	if state.game_over:
		finished.emit(state)
	return true


func _commit(legal: Array[MTGAction], action: MTGAction) -> void:
	var index := -1
	if action != null:
		for i in range(legal.size()):
			if legal[i].equals(action):
				index = i
				break
	if index != -1:
		action = legal[index]           # already known to be legal: skip re-validation
	elif action == null or not engine.is_action_legal(state, action):
		action = legal[0]
		index = 0
	decision_made.emit(state, legal, index)
	apply(action, false)


## Stops run_async() at its next opportunity.
func abort() -> void:
	_aborted = true


## Interactive loop. Awaits agents (a HumanAgent suspends until the UI answers)
## and pauses `ai_delay` seconds after automatic moves so they can be followed.
func run_async(tree: SceneTree, ai_delay: float = 0.6) -> void:
	while not _aborted and not state.game_over and actions_taken < max_actions:
		var legal := legal_actions()
		if legal.is_empty():
			break
		var agent := current_agent()
		var action: MTGAction = await agent.choose_action(state, legal)
		if _aborted:
			return
		_commit(legal, action)
		var automatic := true
		if agent is HumanAgent:
			automatic = (agent as HumanAgent).last_choice_was_automatic
		if automatic and ai_delay > 0.0 and not state.game_over:
			await tree.create_timer(ai_delay).timeout
	if not _aborted and not state.game_over:
		finished.emit(state)


## Headless loop for AI-only games (training, tests). Never suspends.
func run_sync() -> MTGGameState:
	while not state.game_over and actions_taken < max_actions:
		var legal := legal_actions()
		if legal.is_empty():
			break
		_commit(legal, current_agent().choose_action(state, legal))
	if not state.game_over:
		finished.emit(state)
	return state
