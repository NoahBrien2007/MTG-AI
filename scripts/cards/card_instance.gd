class_name CardInstance
extends RefCounted


var instance_id: int
var definition: CardDefinition

var owner_id: int
var controller_id: int

var tapped: bool = false


func _init(
	id: int,
	card_definition: CardDefinition,
	owner: int
) -> void:

	instance_id = id
	definition = card_definition

	owner_id = owner
	controller_id = owner
