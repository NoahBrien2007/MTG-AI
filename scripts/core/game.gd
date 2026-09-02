class_name MTGGame
extends RefCounted


var turn_number: int = 1
var active_player: int = 0

var players: Array[MTGPlayer] = []


func setup_game() -> void:
	players.clear()

	players.append(MTGPlayer.new(0))
	players.append(MTGPlayer.new(1))


func start_game() -> void:
	turn_number = 1
	active_player = 0
