class_name MTGZone
extends RefCounted


enum ZoneType {
	LIBRARY,
	HAND,
	BATTLEFIELD,
	GRAVEYARD,
	EXILE,
	COMMAND,
	STACK
}


var zone_type: ZoneType
var cards: Array[CardInstance] = []


func _init(type: ZoneType) -> void:
	zone_type = type
