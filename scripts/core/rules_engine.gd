class_name MTGRulesEngine
extends RefCounted


func get_legal_actions(state: MTGGameState) -> Array[MTGAction]:
	var actions: Array[MTGAction] = []

	# Placeholder.
	# We will eventually generate every legal action.

	actions.append(
		MTGAction.new(
			MTGAction.ActionType.PASS_PRIORITY,
			state.priority_player
		)
	)

	return actions


func apply_action(
	state: MTGGameState,
	action: MTGAction
) -> MTGGameState:

	var new_state := state.duplicate_state()

	# Actual rules implementation later.

	return new_state
