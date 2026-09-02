class_name MTGPlayer
extends RefCounted


var player_id: int
var life: int = 20

var library: Array = []
var hand: Array = []
var battlefield: Array = []
var graveyard: Array = []
var exile: Array = []

var mana_pool: Dictionary = {
	"W": 0,
	"U": 0,
	"B": 0,
	"R": 0,
	"G": 0,
	"C": 0
}


func _init(id: int) -> void:
	player_id = id
