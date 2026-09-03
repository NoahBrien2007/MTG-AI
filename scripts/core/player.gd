class_name MTGPlayer
extends RefCounted

const COLORS := ["W", "U", "B", "R", "G", "C"]

var player_id: int
var life: int = 20
var has_lost: bool = false

var library: Array[CardInstance] = []
var hand: Array[CardInstance] = []
var battlefield: Array[CardInstance] = []
var graveyard: Array[CardInstance] = []
var exile: Array[CardInstance] = []

var mana_pool: Dictionary = {"W": 0, "U": 0, "B": 0, "R": 0, "G": 0, "C": 0}


func _init(id: int = 0) -> void:
	player_id = id


func reset_mana_pool() -> void:
	for color in mana_pool.keys():
		mana_pool[color] = 0


func add_mana(color: String, amount: int) -> void:
	if mana_pool.has(color):
		mana_pool[color] += amount


func total_mana() -> int:
	var total := 0
	for color in COLORS:
		total += mana_pool[color]
	return total


## cost schema: {"U": 1, "R": 1, "generic": 2}. Generic mana can be paid with any colour.
func has_mana_available(cost: Dictionary) -> bool:
	var leftover := 0
	for color in COLORS:
		var need: int = cost.get(color, 0)
		var have: int = mana_pool.get(color, 0)
		if have < need:
			return false
		leftover += have - need
	return leftover >= int(cost.get("generic", 0))


func spend_mana(cost: Dictionary) -> bool:
	if not has_mana_available(cost):
		return false

	for color in COLORS:
		mana_pool[color] -= int(cost.get(color, 0))

	# Pay generic mana from the largest remaining pools first.
	var generic: int = cost.get("generic", 0)
	while generic > 0:
		var best_color := ""
		var best_amount := 0
		for color in COLORS:
			if mana_pool[color] > best_amount:
				best_amount = mana_pool[color]
				best_color = color
		if best_color.is_empty():
			return false
		mana_pool[best_color] -= 1
		generic -= 1
	return true


func mana_pool_text() -> String:
	var parts: PackedStringArray = []
	for color in COLORS:
		if mana_pool[color] > 0:
			parts.append("%s:%d" % [color, mana_pool[color]])
	return " ".join(parts) if not parts.is_empty() else "empty"


func draw_card() -> CardInstance:
	if library.is_empty():
		has_lost = true
		return null
	var card: CardInstance = library.pop_back()
	hand.append(card)
	return card


func duplicate_player() -> MTGPlayer:
	var copy := MTGPlayer.new(player_id)
	copy.life = life
	copy.has_lost = has_lost
	copy.mana_pool = mana_pool.duplicate()

	for card in library:
		copy.library.append(card.duplicate_instance())
	for card in hand:
		copy.hand.append(card.duplicate_instance())
	for card in battlefield:
		copy.battlefield.append(card.duplicate_instance())
	for card in graveyard:
		copy.graveyard.append(card.duplicate_instance())
	for card in exile:
		copy.exile.append(card.duplicate_instance())

	return copy
