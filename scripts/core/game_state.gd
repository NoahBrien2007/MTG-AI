class_name MTGGameState
extends RefCounted

## Complete, self-contained snapshot of a game. The rules engine never mutates a
## state in place: apply_action() returns a deep copy, so states can be searched,
## recorded or rewound freely.

enum Phase {
	BEGINNING,
	PRECOMBAT_MAIN,
	COMBAT,
	POSTCOMBAT_MAIN,
	ENDING
}

enum Step {
	UNTAP,
	UPKEEP,
	DRAW,
	MAIN_1,
	BEGIN_COMBAT,
	DECLARE_ATTACKERS,
	DECLARE_BLOCKERS,
	COMBAT_DAMAGE,
	END_COMBAT,
	MAIN_2,
	END_STEP,
	CLEANUP
}

const STEP_NAMES := {
	Step.UNTAP: "Untap",
	Step.UPKEEP: "Upkeep",
	Step.DRAW: "Draw",
	Step.MAIN_1: "Main Phase 1",
	Step.BEGIN_COMBAT: "Beginning of Combat",
	Step.DECLARE_ATTACKERS: "Declare Attackers",
	Step.DECLARE_BLOCKERS: "Declare Blockers",
	Step.COMBAT_DAMAGE: "Combat Damage",
	Step.END_COMBAT: "End of Combat",
	Step.MAIN_2: "Main Phase 2",
	Step.END_STEP: "End Step",
	Step.CLEANUP: "Cleanup"
}

var turn_number: int = 1
var active_player: int = 0
var priority_player: int = 0

var current_phase: Phase = Phase.BEGINNING
var current_step: Step = Step.UNTAP

var land_played_this_turn: bool = false
var consecutive_passes: int = 0

var players: Array[MTGPlayer] = []
# Stack item schema: {"card": CardInstance, "controller": int, "targets": Array of slots, "kicked": bool}
var stack: Array[Dictionary] = []

## Non-empty while an effect waits for a decision (scry, pick a card, pay or not,
## choose trigger targets). Schema: {"kind", "player", "options": [{"label", …}], "ctx", "data"}
## While set, the only legal actions are CHOOSE actions by `pending_choice.player`.
var pending_choice: Dictionary = {}
## Triggered abilities waiting to resolve (see Triggers / Effects.drain).
var trigger_queue: Array[Dictionary] = []

var declared_attackers: Array[int] = []       # card instance IDs
var declared_blockers: Dictionary = {}        # blocker_instance_id -> attacker_instance_id

var game_over: bool = false
var winner_id: int = -1

var next_instance_id: int = 1


func get_opponent_id(player_id: int) -> int:
	return 1 - player_id


## The player who has to act next: the pending-choice decider if any, else the priority player.
func acting_player() -> int:
	if not pending_choice.is_empty():
		return pending_choice["player"]
	return priority_player


func has_pending_choice() -> bool:
	return not pending_choice.is_empty()


func is_main_phase() -> bool:
	return current_step == Step.MAIN_1 or current_step == Step.MAIN_2


func step_name() -> String:
	return STEP_NAMES.get(current_step, "?")


func find_card_instance(instance_id: int) -> CardInstance:
	for player in players:
		for zone in [player.hand, player.battlefield, player.graveyard, player.exile, player.library]:
			for card in zone:
				if card.instance_id == instance_id:
					return card
	for item in stack:
		var card: CardInstance = item["card"]
		if card.instance_id == instance_id:
			return card
	return null


## Returns {"player": MTGPlayer, "zone_name": String, "card": CardInstance} or {} if not found.
## zone_name is one of: hand, battlefield, graveyard, exile, library, stack.
func find_card_location(instance_id: int) -> Dictionary:
	for player in players:
		var zones := {
			"hand": player.hand,
			"battlefield": player.battlefield,
			"graveyard": player.graveyard,
			"exile": player.exile,
			"library": player.library
		}
		for zone_name in zones.keys():
			for card in zones[zone_name]:
				if card.instance_id == instance_id:
					return {"player": player, "zone_name": zone_name, "card": card}
	for item in stack:
		var card: CardInstance = item["card"]
		if card.instance_id == instance_id:
			return {"player": players[item["controller"]], "zone_name": "stack", "card": card}
	return {}


func duplicate_state() -> MTGGameState:
	var copy := MTGGameState.new()

	copy.turn_number = turn_number
	copy.active_player = active_player
	copy.priority_player = priority_player
	copy.current_phase = current_phase
	copy.current_step = current_step
	copy.land_played_this_turn = land_played_this_turn
	copy.consecutive_passes = consecutive_passes
	copy.game_over = game_over
	copy.winner_id = winner_id
	copy.next_instance_id = next_instance_id

	for player in players:
		copy.players.append(player.duplicate_player())

	for item in stack:
		copy.stack.append({
			"card": item["card"].duplicate_instance(),
			"controller": item["controller"],
			"targets": item["targets"].duplicate(true),
			"kicked": item["kicked"],
		})

	copy.declared_attackers = declared_attackers.duplicate()
	copy.declared_blockers = declared_blockers.duplicate()
	copy.pending_choice = pending_choice.duplicate(true)
	copy.trigger_queue = trigger_queue.duplicate(true)

	return copy
