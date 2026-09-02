extends Node


func _ready() -> void:
	var game := MTGGame.new()

	game.setup_game()

	print("Game created!")
	print("Players: ", game.players.size())

	for player in game.players:
		print(
			"Player ",
			player.player_id,
			" life = ",
			player.life
		)
