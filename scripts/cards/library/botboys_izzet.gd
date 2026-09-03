class_name CardsBotboysIzzet
extends RefCounted

## Rules-as-data for every card in data/decks/botboys_deck_izzet.txt.
## Register new sets of cards in CardLibrary.SOURCES. Anything not listed here
## falls back to OracleParser, which handles simple templated text.
##
## Keep entries declarative: the engine (Effects / Targeting / Triggers) is the
## only place that knows what an effect *does*. Adding a card that only combines
## existing effects means adding an entry here, nothing else.

const CARDS := {
	# ───────────── Lands ─────────────
	"Island": {
		"mana": [{"color": "U"}],
	},
	"Steam Vents": {
		"mana": [{"color": "U"}, {"color": "R"}],
		"enter_choices": ["pay_2_life_or_tapped"],
	},
	"Spirebluff Canal": {
		"mana": [{"color": "U"}, {"color": "R"}],
		"enters_tapped": "more_than_two_other_lands",
	},
	"Riverpyre Verge": {
		"mana": [
			{"color": "R"},
			{"color": "U", "condition": "controls_island_or_mountain"},
		],
	},
	"Multiversal Passage": {
		# Mana ability comes from the chosen basic land type (CardInstance.chosen_land_type).
		"enter_choices": ["choose_basic_land_type", "pay_2_life_or_tapped"],
	},

	# ───────────── Creatures ─────────────
	"Eddymurk Crab": {
		"cost_reduction": {"per": "instant_sorcery_in_graveyard", "amount": 1},
		"enters_tapped": "not_your_turn",
		"triggers": [{
			"event": "etb",
			"targets": [{"kind": "creature", "max": 2, "optional": true}],
			"effects": [{"type": "tap", "target": 0}],
		}],
	},
	"Hydro-Man, Fluid Felon": {
		"triggers": [
			{
				"event": "cast_spell",
				"filter": {"color": "U"},
				"condition": "source_is_creature",
				"effects": [{"type": "pump_self", "power": 1, "toughness": 1}],
			},
			{
				"event": "end_step",
				"effects": [{"type": "untap_self"}, {"type": "become_land_until_your_next_turn"}],
			},
		],
	},
	"Slickshot Show-Off": {
		# Flying and haste come from the keywords column. Plot is not implemented.
		"triggers": [{
			"event": "cast_spell",
			"filter": {"noncreature": true},
			"effects": [{"type": "pump_self", "power": 2, "toughness": 0}],
		}],
	},

	# ───────────── Enchantment ─────────────
	"Stormchaser's Talent": {
		"triggers": [
			{
				"event": "etb",
				"effects": [{"type": "create_token", "token": "otter_prowess"}],
			},
			{
				"event": "level_up",
				"filter": {"level": 2},
				"targets": [{"kind": "graveyard_instant_sorcery_yours", "optional": true}],
				"effects": [{"type": "return_from_graveyard", "target": 0}],
			},
			{
				"event": "cast_spell",
				"filter": {"instant_or_sorcery": true},
				"condition": "class_level>=3",
				"effects": [{"type": "create_token", "token": "otter_prowess"}],
			},
		],
		"abilities": [
			{"label": "Level 2", "cost": "{3}{U}", "sorcery_speed": true,
				"condition": "class_level==1", "effects": [{"type": "level_up"}]},
			{"label": "Level 3", "cost": "{5}{U}", "sorcery_speed": true,
				"condition": "class_level==2", "effects": [{"type": "level_up"}]},
		],
	},

	# ───────────── Instants ─────────────
	"Burst Lightning": {
		"kicker": "{4}",
		"targets": [{"kind": "any"}],
		"spell": [{"type": "damage", "amount": 2, "kicked_amount": 4, "target": 0}],
	},
	"Opt": {
		"spell": [{"type": "scry", "count": 1}, {"type": "draw", "count": 1}],
	},
	"Shore Up": {
		"targets": [{"kind": "creature_you_control"}],
		"spell": [
			{"type": "pump", "target": 0, "power": 1, "toughness": 1},
			{"type": "grant_keyword", "target": 0, "keyword": "hexproof"},
			{"type": "untap", "target": 0},
		],
	},
	"Spell Pierce": {
		"targets": [{"kind": "spell_noncreature"}],
		"spell": [{"type": "counter_unless_pays", "target": 0, "cost": "{2}"}],
	},
	"Vibrant Outburst": {
		"targets": [{"kind": "any"}, {"kind": "creature", "optional": true}],
		"spell": [
			{"type": "damage", "amount": 3, "target": 0},
			{"type": "tap", "target": 1},
		],
	},

	# ───────────── Sorceries ─────────────
	"Boomerang Basics": {
		"targets": [{"kind": "nonland_permanent"}],
		"spell": [{"type": "bounce", "target": 0, "draw_if_controlled": true}],
	},
	"Flow State": {
		"spell": [{"type": "look_and_take", "look": 3, "take": 1,
			"take_alt": 2, "alt_condition": "instant_and_sorcery_in_graveyard"}],
	},
	"Sleight of Hand": {
		"spell": [{"type": "look_and_take", "look": 2, "take": 1}],
	},
}
