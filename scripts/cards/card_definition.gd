class_name CardDefinition
extends Resource

## Static, shared data about one card (or token). Never mutated during a game —
## per-game state lives on CardInstance.
##
## `rules` holds the card's rules as data (see scripts/cards/library/README in
## card_library.gd). It is either hand-written in the card library or derived
## from the oracle text by OracleParser.

enum CardType {
	LAND,
	CREATURE,
	INSTANT,
	SORCERY,
	ENCHANTMENT,
	ARTIFACT
}

@export var card_id: String
@export var card_name: String
@export var card_type: CardType = CardType.CREATURE

@export var mana_cost: String
@export var parsed_cost: Dictionary = {}          # e.g. {"U": 1, "generic": 2}
@export var mana_value: int = 0

@export var type_line: String
@export var subtypes: PackedStringArray = []      # e.g. ["Island", "Mountain"], ["Class"]
@export var supertypes: PackedStringArray = []    # e.g. ["Basic", "Legendary"]
@export var colors: PackedStringArray = []        # e.g. ["U", "R"]
@export var keywords: PackedStringArray = []      # lower-case, e.g. ["flash", "flying"]
@export_multiline var oracle_text: String

@export var power: int = 0
@export var toughness: int = 0

@export var is_token: bool = false

## Rules-as-data. Keys (all optional):
##   mana:        Array of {"color": "U", "condition": "..."}   — {T}: Add mana abilities
##   spell:       Array of effects resolved when an instant/sorcery resolves
##   targets:     Array of target specs for the spell (see Targeting)
##   kicker:      mana cost string, e.g. "{4}"
##   cost_reduction: {"per": "instant_sorcery_in_graveyard", "amount": 1}
##   enters_tapped: condition string ("not_your_turn", "more_than_two_other_lands")
##   enter_choices: Array of replacement choices ("pay_2_life_or_tapped", "choose_basic_land_type")
##   triggers:    Array of {"event": ..., "filter": {...}, "targets": [...], "effects": [...]}
##   abilities:   Array of activated abilities {"cost": "{3}{U}", "label": ..., "sorcery_speed": true,
##                "condition": ..., "effects": [...]}
##   token:       for token definitions, the token id
@export var rules: Dictionary = {}


func is_permanent() -> bool:
	return card_type != CardType.INSTANT and card_type != CardType.SORCERY


func is_creature() -> bool:
	return card_type == CardType.CREATURE


func is_land() -> bool:
	return card_type == CardType.LAND


func is_instant_or_sorcery() -> bool:
	return card_type == CardType.INSTANT or card_type == CardType.SORCERY


func has_keyword(keyword: String) -> bool:
	return keywords.has(keyword.to_lower())


func has_subtype(subtype: String) -> bool:
	return subtypes.has(subtype)


func is_color(color: String) -> bool:
	return colors.has(color)


func type_name() -> String:
	return CardType.keys()[card_type].capitalize()
