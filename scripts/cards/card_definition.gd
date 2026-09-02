class_name CardDefinition
extends Resource


@export var card_id: String
@export var card_name: String

@export var mana_cost: String
@export var type_line: String

@export_multiline var oracle_text: String

@export var power: int = 0
@export var toughness: int = 0
