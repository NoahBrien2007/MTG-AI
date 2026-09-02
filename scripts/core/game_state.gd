class_name MTGGameState
extends RefCounted


var turn_number: int = 1
var active_player: int = 0

var current_phase: String = "UNTAP"
var current_step: String = "UNTAP"

var priority_player: int = 0

var players: Array[MTGPlayer] = []


func duplicate_state() -> MTGGameState:
	var copy := MTGGameState.new()

	copy.turn_number = turn_number
	copy.active_player = active_player
	copy.current_phase = current_phase
	copy.current_step = current_step
	copy.priority_player = priority_player

	# Deep copying will be implemented later.

	return copy
