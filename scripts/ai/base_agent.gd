class_name BaseAgent
extends RefCounted

var player_id: int = 0
var agent_name: String = "BaseAgent"


func _init(id: int = 0, name: String = "BaseAgent") -> void:
	player_id = id
	agent_name = name


func choose_action(_state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null
	return legal_actions[0]
