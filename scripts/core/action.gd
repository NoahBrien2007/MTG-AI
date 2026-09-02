class_name MTGAction
extends RefCounted


enum ActionType {
	PASS_PRIORITY,
	PLAY_LAND,
	CAST_SPELL,
	ACTIVATE_ABILITY,
	ATTACK,
	BLOCK,
	SPECIAL
}


var action_type: ActionType

var player_id: int
var card_instance_id: int = -1

var targets: Array[int] = []


func _init(type: ActionType, player: int) -> void:
	action_type = type
	player_id = player
