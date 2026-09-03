class_name CardInstance
extends RefCounted

## One physical card (or token) inside a game. Holds everything about the card
## that can change during play. Must stay cheap to duplicate — states are deep
## copied on every action.

var instance_id: int
var definition: CardDefinition

var owner_id: int
var controller_id: int

var tapped: bool = false
var damage_marked: int = 0
var summoned_this_turn: bool = true

# Until end of turn
var temp_power_bonus: int = 0
var temp_toughness_bonus: int = 0
var temp_keywords: PackedStringArray = []

# Longer-lived modifiers
var class_level: int = 0             # Class enchantments
var chosen_land_type: String = ""    # "As this enters, choose a basic land type"
var is_land_until_next_turn: bool = false  # Hydro-Man style animation

const BASIC_TYPE_COLORS := {"Plains": "W", "Island": "U", "Swamp": "B", "Mountain": "R", "Forest": "G"}


func _init(id: int = -1, card_definition: CardDefinition = null, owner: int = -1) -> void:
	instance_id = id
	definition = card_definition
	owner_id = owner
	controller_id = owner


# ───────────────────────────── Types ─────────────────────────────

## The card's current type, including temporary type changes.
func current_type() -> CardDefinition.CardType:
	if is_land_until_next_turn:
		return CardDefinition.CardType.LAND
	return definition.card_type if definition else CardDefinition.CardType.CREATURE


func is_creature() -> bool:
	return current_type() == CardDefinition.CardType.CREATURE


func is_land() -> bool:
	return current_type() == CardDefinition.CardType.LAND


func is_permanent() -> bool:
	return definition != null and definition.is_permanent()


func has_subtype(subtype: String) -> bool:
	if chosen_land_type == subtype:
		return true
	return definition != null and definition.has_subtype(subtype)


func has_keyword(keyword: String) -> bool:
	var k := keyword.to_lower()
	if temp_keywords.has(k):
		return true
	return definition != null and definition.has_keyword(k) and is_creature()


func is_color(color: String) -> bool:
	return definition != null and definition.is_color(color)


# ───────────────────────────── Stats ─────────────────────────────

func get_power() -> int:
	if is_creature():
		return definition.power + temp_power_bonus
	return 0


func get_toughness() -> int:
	if is_creature():
		return definition.toughness + temp_toughness_bonus
	return 0


func can_attack() -> bool:
	if not is_creature() or tapped:
		return false
	if summoned_this_turn and not has_keyword("haste"):
		return false
	return true


func can_block(attacker: CardInstance) -> bool:
	if not is_creature() or tapped:
		return false
	if attacker.has_keyword("flying") and not (has_keyword("flying") or has_keyword("reach")):
		return false
	return true


## Colours this permanent can currently tap for: Array of {"color": String, "condition": String}.
func mana_abilities() -> Array:
	var abilities: Array = []
	if is_land_until_next_turn:
		abilities.append({"color": "U", "condition": ""})
		return abilities
	if not is_land() or definition == null:
		return abilities
	if not chosen_land_type.is_empty() and BASIC_TYPE_COLORS.has(chosen_land_type):
		abilities.append({"color": BASIC_TYPE_COLORS[chosen_land_type], "condition": ""})
	for ability in definition.rules.get("mana", []):
		abilities.append(ability)
	return abilities


func clear_until_end_of_turn() -> void:
	damage_marked = 0
	temp_power_bonus = 0
	temp_toughness_bonus = 0
	temp_keywords = PackedStringArray()


func duplicate_instance() -> CardInstance:
	var copy := CardInstance.new(instance_id, definition, owner_id)
	copy.controller_id = controller_id
	copy.tapped = tapped
	copy.damage_marked = damage_marked
	copy.summoned_this_turn = summoned_this_turn
	copy.temp_power_bonus = temp_power_bonus
	copy.temp_toughness_bonus = temp_toughness_bonus
	copy.temp_keywords = temp_keywords.duplicate()
	copy.class_level = class_level
	copy.chosen_land_type = chosen_land_type
	copy.is_land_until_next_turn = is_land_until_next_turn
	return copy
