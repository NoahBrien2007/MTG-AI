class_name CardsTokens
extends RefCounted

## Token definitions, keyed by the id used in "create_token" effects.

const TOKENS := {
	"otter_prowess": {
		"name": "Otter",
		"type_line": "Token Creature — Otter",
		"card_type": CardDefinition.CardType.CREATURE,
		"subtypes": ["Otter"],
		"colors": ["U", "R"],
		"keywords": ["prowess"],
		"power": 1,
		"toughness": 1,
	},
}
