class_name RandomAgent
extends BaseAgent


func _init(id: int = 0) -> void:
	super._init(id, "RandomAgent")


func choose_action(state: MTGGameState, legal_actions: Array[MTGAction]) -> MTGAction:
	if legal_actions.is_empty():
		return null
	return legal_actions[randi() % legal_actions.size()]
