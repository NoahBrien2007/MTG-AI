class_name StateEncoder
extends RefCounted

## Turns a game state into fixed-size numeric vectors from one player's point
## of view — the input representation for learned agents.
##
## encode(state, player) returns:
##   "features":  PackedFloat32Array   — global features followed by CARD_FEATURES
##                                       floats for every card slot (see layout below)
##   "card_ids":  PackedInt32Array     — one vocabulary index per card slot (0 = empty),
##                                       for a learned per-card embedding
##
## Slot layout (in order): my hand (HAND_SLOTS), my battlefield (BATTLEFIELD_SLOTS),
## opponent battlefield (BATTLEFIELD_SLOTS), stack (STACK_SLOTS).
## Hidden information (opponent's hand, libraries) is only exposed as counts.
##
## The card vocabulary is loaded from VOCAB_PATH when present so that card ids
## stay identical across runs (a trained model's embedding table depends on it).
## Regenerate that file with:  python -m mtgai.vocab   (see ai/python/README.md)

const HAND_SLOTS := 10
const BATTLEFIELD_SLOTS := 12
const STACK_SLOTS := 3
const STEP_COUNT := 12

const KEYWORDS := ["flying", "haste", "flash", "prowess", "hexproof", "reach"]
const COLORS := ["W", "U", "B", "R", "G"]

## Per-card feature count: present, 6 types, mana value, power, toughness, tapped,
## summoning sick, damage, is_token, is_mine, 5 colours, 6 keywords, class level, attacking, blocking,
## and 5 for what a spell on the stack is aimed at (see _encode_card).
const CARD_FEATURES := 1 + 6 + 3 + 3 + 1 + 1 + 5 + 6 + 3 + 5

## Length of the vector returned by encode_action(): the 9-way type one-hot plus
## the 9 values listed above it. This said 9 + 10 until a policy trained on the
## recordings refused to load them — nothing had ever checked the constant
## against the function, because nothing used it. The recorder now writes it into
## every dataset header, so the two cannot drift apart again.
const ACTION_FEATURES := 9 + 9

const VOCAB_PATH := "res://ai/training/vocabulary.json"

static var _vocab: Dictionary = {}       # card name -> index (1-based)
static var _vocab_names: PackedStringArray = [""]
static var _vocab_loaded: bool = false


static func total_slots() -> int:
	return HAND_SLOTS + BATTLEFIELD_SLOTS * 2 + STACK_SLOTS


static func global_feature_count() -> int:
	return 7 + STEP_COUNT + 6 + 12


static func feature_count() -> int:
	return global_feature_count() + total_slots() * CARD_FEATURES


static func vocabulary() -> PackedStringArray:
	_load_vocabulary()
	return _vocab_names


## Reads the canonical vocabulary once, so card ids match the ids a trained
## model was built with. Cards missing from the file are appended at the end.
static func _load_vocabulary() -> void:
	if _vocab_loaded:
		return
	_vocab_loaded = true
	if not FileAccess.file_exists(VOCAB_PATH):
		return
	var file := FileAccess.open(VOCAB_PATH, FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text())
	var names: Array = data if data is Array else (data.get("vocabulary", []) if data is Dictionary else [])
	for name in names:
		var card_name := str(name)
		if card_name.is_empty() or _vocab.has(card_name):
			continue
		_vocab[card_name] = _vocab_names.size()
		_vocab_names.append(card_name)


static func card_index(card_name: String) -> int:
	_load_vocabulary()
	if not _vocab.has(card_name):
		_vocab[card_name] = _vocab_names.size()
		_vocab_names.append(card_name)
	return _vocab[card_name]


static func encode(state: MTGGameState, player_id: int) -> Dictionary:
	var me := state.players[player_id]
	var opp := state.players[1 - player_id]
	var f := PackedFloat32Array()
	var ids := PackedInt32Array()

	# ── Global (7) ──
	f.append(minf(state.turn_number / 30.0, 1.0))
	f.append(1.0 if state.starting_player == player_id else 0.0)
	f.append(1.0 if state.active_player == player_id else 0.0)
	f.append(1.0 if state.acting_player() == player_id else 0.0)
	f.append(1.0 if state.has_pending_choice() else 0.0)
	f.append(minf(state.stack.size() / 3.0, 1.0))
	f.append(1.0 if state.land_played_this_turn else 0.0)

	# ── Step one-hot (12) ──
	for i in range(STEP_COUNT):
		f.append(1.0 if state.current_step == i else 0.0)

	# ── My mana pool (6) ──
	for color in MTGPlayer.COLORS:
		f.append(minf(me.mana_pool[color] / 6.0, 1.0))

	# ── Counts (12) ──
	f.append(me.life / 20.0)
	f.append(opp.life / 20.0)
	f.append(me.hand.size() / 10.0)
	f.append(opp.hand.size() / 10.0)
	f.append(me.library.size() / 60.0)
	f.append(opp.library.size() / 60.0)
	f.append(me.graveyard.size() / 30.0)
	f.append(opp.graveyard.size() / 30.0)
	f.append(_count_lands(me) / 10.0)
	f.append(_count_lands(opp) / 10.0)
	f.append(_count_untapped_lands(me) / 10.0)
	f.append(_count_untapped_lands(opp) / 10.0)

	# ── Card slots ──
	_encode_zone(f, ids, me.hand, HAND_SLOTS, state, player_id)
	_encode_zone(f, ids, me.battlefield, BATTLEFIELD_SLOTS, state, player_id)
	_encode_zone(f, ids, opp.battlefield, BATTLEFIELD_SLOTS, state, player_id)
	var stack_cards: Array[CardInstance] = []
	for item in state.stack:
		stack_cards.append(item["card"])
	_encode_zone(f, ids, stack_cards, STACK_SLOTS, state, player_id, state.stack)

	return {"features": f, "card_ids": ids}


## `items` is the matching stack entries when this zone is the stack, empty
## otherwise — a card in hand or on the battlefield targets nothing.
static func _encode_zone(f: PackedFloat32Array, ids: PackedInt32Array, cards: Array[CardInstance], slots: int, state: MTGGameState, viewer: int, items: Array = []) -> void:
	for i in range(slots):
		if i < cards.size():
			_encode_card(f, ids, cards[i], state, viewer, items[i] if i < items.size() else {})
		else:
			for j in range(CARD_FEATURES):
				f.append(0.0)
			ids.append(0)


static func _encode_card(f: PackedFloat32Array, ids: PackedInt32Array, card: CardInstance, state: MTGGameState, viewer: int, item: Dictionary = {}) -> void:
	var def := card.definition
	f.append(1.0)
	for t in range(6):
		f.append(1.0 if card.current_type() == t else 0.0)
	f.append(minf(def.mana_value / 8.0, 1.0) if def else 0.0)
	f.append(minf(card.get_power() / 8.0, 1.0))
	f.append(minf(card.get_toughness() / 8.0, 1.0))
	f.append(1.0 if card.tapped else 0.0)
	f.append(1.0 if card.summoned_this_turn else 0.0)
	f.append(minf(card.damage_marked / 8.0, 1.0))
	f.append(1.0 if def and def.is_token else 0.0)
	f.append(1.0 if card.controller_id == viewer else 0.0)
	for color in COLORS:
		f.append(1.0 if card.is_color(color) else 0.0)
	for kw in KEYWORDS:
		f.append(1.0 if card.has_keyword(kw) else 0.0)
	f.append(card.class_level / 3.0)
	f.append(1.0 if card.instance_id in state.declared_attackers else 0.0)
	f.append(1.0 if state.declared_blockers.has(card.instance_id) else 0.0)

	# ── What this is aimed at (5) ── zero everywhere except the stack.
	#
	# Without these, a burn spell pointed at the opponent and the same spell
	# pointed at my own face produce identical vectors, so no model trained on
	# this encoding can prefer one. A searching agent then picks whichever plan
	# came first and burns itself. Kicked matters for the same reason: it is the
	# difference between 1 damage and 4 about to land.
	var aims_at_me := 0.0
	var aims_at_opponent := 0.0
	var aims_at_my_permanent := 0.0
	var aims_at_opponent_permanent := 0.0
	for slot in item.get("targets", []):
		var target_player: int = int(slot.get("player", -1))
		if target_player == viewer:
			aims_at_me = 1.0
		elif target_player >= 0:
			aims_at_opponent = 1.0
		var target_card := state.find_card_instance(int(slot.get("card", -1)))
		if target_card:
			if target_card.controller_id == viewer:
				aims_at_my_permanent = 1.0
			else:
				aims_at_opponent_permanent = 1.0
	f.append(aims_at_me)
	f.append(aims_at_opponent)
	f.append(aims_at_my_permanent)
	f.append(aims_at_opponent_permanent)
	f.append(1.0 if item.get("kicked", false) else 0.0)

	ids.append(card_index(def.card_name) if def else 0)


static func _count_lands(player: MTGPlayer) -> int:
	var n := 0
	for card in player.battlefield:
		if card.is_land():
			n += 1
	return n


static func _count_untapped_lands(player: MTGPlayer) -> int:
	var n := 0
	for card in player.battlefield:
		if card.is_land() and not card.tapped:
			n += 1
	return n


## Compact numeric description of an action, relative to the acting player.
## [type one-hot (9), card slot index / 40, n targets / 3, targets opponent player,
##  targets own card, targets opp card, kicked, choice index / 8, n attackers / 8, ability index / 4]
static func encode_action(action: MTGAction, state: MTGGameState, player_id: int) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	for t in range(9):
		f.append(1.0 if action.action_type == t else 0.0)
	f.append(_slot_index(state, player_id, action.card_instance_id) / 40.0)
	f.append(minf(action.targets.size() / 3.0, 1.0))
	var opp_player := 0.0
	var own_card := 0.0
	var opp_card := 0.0
	for slot in action.targets:
		if slot.get("player", -1) == 1 - player_id:
			opp_player = 1.0
		var target := state.find_card_instance(slot.get("card", -1))
		if target:
			if target.controller_id == player_id:
				own_card = 1.0
			else:
				opp_card = 1.0
	f.append(opp_player)
	f.append(own_card)
	f.append(opp_card)
	f.append(1.0 if action.kicked else 0.0)
	f.append(maxf(action.choice_index, 0) / 8.0)
	f.append(minf(action.attacker_ids.size() / 8.0, 1.0))
	f.append(maxf(action.ability_index, 0) / 4.0)
	return f


## Position of a card in the encoded slots (hand first, then my battlefield, then
## opponent battlefield, then stack) or -1.
static func _slot_index(state: MTGGameState, player_id: int, card_id: int) -> int:
	if card_id == -1:
		return -1
	var me := state.players[player_id]
	var opp := state.players[1 - player_id]
	var zones := [me.hand, me.battlefield, opp.battlefield]
	var sizes := [HAND_SLOTS, BATTLEFIELD_SLOTS, BATTLEFIELD_SLOTS]
	var offset := 0
	for z in range(zones.size()):
		for i in range(mini(zones[z].size(), sizes[z])):
			if zones[z][i].instance_id == card_id:
				return offset + i
		offset += sizes[z]
	for i in range(mini(state.stack.size(), STACK_SLOTS)):
		if state.stack[i]["card"].instance_id == card_id:
			return offset + i
	return -1
