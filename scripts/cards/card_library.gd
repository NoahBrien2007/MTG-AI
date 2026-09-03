class_name CardLibrary
extends RefCounted

## Registry of hand-written card scripts (rules-as-data) and token definitions.
##
## HOW TO ADD CARDS
##   1. Add the card to a deck list and run `python tools/extract_cards.py`
##      so data/cards/cards.json has its printed data (cost, types, text…).
##   2. If OracleParser cannot derive its rules from the text, add an entry to a
##      library file (see botboys_izzet.gd) and list that file in SOURCES.
##   3. If the card needs an effect the engine doesn't have yet, add it to
##      Effects (and, for new target kinds, Targeting). That is the only code.
##
## SCRIPT FORMAT — a Dictionary with any of these keys:
##   "mana":           [{"color": "U", "condition": <cond>}]
##   "spell":          [<effect>, …]           resolved when an instant/sorcery resolves
##   "targets":        [<target spec>, …]      targets chosen when the spell is cast
##   "kicker":         "{4}"
##   "cost_reduction": {"per": "instant_sorcery_in_graveyard", "amount": 1}
##   "enters_tapped":  <cond>
##   "enter_choices":  ["pay_2_life_or_tapped", "choose_basic_land_type"]
##   "triggers":       [{"event": "etb"|"cast_spell"|"end_step"|"level_up",
##                       "filter": {...}, "condition": <cond>, "targets": [...], "effects": [...]}]
##   "abilities":      [{"label", "cost", "sorcery_speed", "condition", "targets", "effects"}]
##
## TARGET SPEC: {"kind": <kind>, "optional": bool, "max": int}
##   kinds: any, creature, creature_you_control, nonland_permanent, spell_noncreature,
##          graveyard_instant_sorcery_yours, player
##
## EFFECT: {"type": <type>, …} — see Effects.resolve_effect for the full list:
##   damage, tap, untap, draw, scry, look_and_take, pump, pump_self, grant_keyword,
##   counter_unless_pays, bounce, create_token, return_from_graveyard, untap_self,
##   become_land_until_your_next_turn, level_up
##
## CONDITIONS (strings evaluated by Conditions.check):
##   not_your_turn, more_than_two_other_lands, controls_island_or_mountain,
##   source_is_creature, class_level==N, class_level>=N, instant_and_sorcery_in_graveyard

const SOURCES: Array = [
	CardsBotboysIzzet.CARDS,
]

static var _scripts: Dictionary = {}   # lower-case name -> script
static var _built: bool = false


static func get_script_for(card_name: String) -> Dictionary:
	_build()
	return _scripts.get(card_name.to_lower(), {})


static func has_script(card_name: String) -> bool:
	_build()
	return _scripts.has(card_name.to_lower())


static func token_definition(token_id: String) -> CardDefinition:
	var data: Dictionary = CardsTokens.TOKENS.get(token_id, {})
	if data.is_empty():
		push_warning("CardLibrary: unknown token '%s'" % token_id)
		return null
	var def := CardDefinition.new()
	def.card_id = "token_" + token_id
	def.card_name = data.get("name", token_id)
	def.type_line = data.get("type_line", "Token")
	def.card_type = data.get("card_type", CardDefinition.CardType.CREATURE)
	def.subtypes = PackedStringArray(data.get("subtypes", []))
	def.colors = PackedStringArray(data.get("colors", []))
	def.keywords = PackedStringArray(data.get("keywords", []))
	def.power = data.get("power", 0)
	def.toughness = data.get("toughness", 0)
	def.is_token = true
	def.rules = data.get("script", {})
	return def


static func _build() -> void:
	if _built:
		return
	_built = true
	for source in SOURCES:
		for card_name in source.keys():
			_scripts[str(card_name).to_lower()] = source[card_name]
