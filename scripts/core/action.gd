class_name MTGAction
extends RefCounted

## A single atomic decision a player (human or AI) can make.
## Everything that happens in a game goes through one of these, which is what
## guarantees the human UI and the AI agents have exactly the same abilities.
##
## Targets are stored as an ordered list of slots, one per target the card
## asks for. A slot is {"card": instance_id} or {"player": player_id}.

enum ActionType {
	PASS_PRIORITY,
	TAP_LAND,               # card_instance_id, mana_color
	PLAY_LAND,              # card_instance_id, options (e.g. pay_life / land_type)
	CAST_SPELL,             # card_instance_id, targets, kicked
	ACTIVATE_ABILITY,       # card_instance_id, ability_index, targets
	DECLARE_ATTACKERS,      # attacker_ids
	DECLARE_BLOCKER,        # blocker_id, blocking_attacker_id
	FINISH_COMBAT_DECLARATIONS,
	CHOOSE                  # choice_index — answers the state's pending choice
}

var action_type: ActionType
var player_id: int

var card_instance_id: int = -1
var mana_color: String = ""
var targets: Array[Dictionary] = []
var kicked: bool = false
var ability_index: int = -1
var choice_index: int = -1
var options: Dictionary = {}          # extra per-action data (PLAY_LAND replacement choices)

var attacker_ids: Array[int] = []
var blocker_id: int = -1
var blocking_attacker_id: int = -1

## Human readable label for choices the UI cannot express by clicking a card.
var label: String = ""


func _init(type: ActionType, player: int) -> void:
	action_type = type
	player_id = player


static func card_target(instance_id: int) -> Dictionary:
	return {"card": instance_id}


static func player_target(pid: int) -> Dictionary:
	return {"player": pid}


func target_card(slot: int = 0) -> int:
	if slot < targets.size() and targets[slot].has("card"):
		return targets[slot]["card"]
	return -1


func target_player(slot: int = 0) -> int:
	if slot < targets.size() and targets[slot].has("player"):
		return targets[slot]["player"]
	return -1


func targets_cards() -> Array[int]:
	var ids: Array[int] = []
	for t in targets:
		if t.has("card"):
			ids.append(t["card"])
	return ids


func targets_players() -> Array[int]:
	var ids: Array[int] = []
	for t in targets:
		if t.has("player"):
			ids.append(t["player"])
	return ids


## Canonical string; two actions are the same decision iff their signatures match.
func signature() -> String:
	var parts: PackedStringArray = [str(action_type), str(player_id)]
	match action_type:
		ActionType.DECLARE_ATTACKERS:
			var ids := attacker_ids.duplicate()
			ids.sort()
			parts.append(str(ids))
		ActionType.DECLARE_BLOCKER:
			parts.append("%d>%d" % [blocker_id, blocking_attacker_id])
		ActionType.TAP_LAND:
			parts.append("%d:%s" % [card_instance_id, mana_color])
		ActionType.CHOOSE:
			parts.append(str(choice_index))
		_:
			parts.append(str(card_instance_id))
			parts.append(str(ability_index))
			parts.append("k" if kicked else "")
			parts.append(JSON.stringify(targets))
			var keys := options.keys()
			keys.sort()
			for k in keys:
				parts.append("%s=%s" % [k, str(options[k])])
	return "|".join(parts)


func equals(other: MTGAction) -> bool:
	return other != null and signature() == other.signature()


## Human readable description. Call BEFORE the action is applied so the cards
## are still in the zones the description refers to.
func describe(state: MTGGameState) -> String:
	var who := "P%d" % player_id
	match action_type:
		ActionType.PASS_PRIORITY:
			return "%s passes" % who
		ActionType.TAP_LAND:
			return "%s taps %s for %s" % [who, _card_name(state, card_instance_id), mana_color]
		ActionType.PLAY_LAND:
			var text := "%s plays %s" % [who, _card_name(state, card_instance_id)]
			if not label.is_empty():
				text += " (%s)" % label
			return text
		ActionType.CAST_SPELL:
			var text := "%s casts %s%s" % [who, _card_name(state, card_instance_id), " (kicked)" if kicked else ""]
			var t := _describe_targets(state)
			return text + (" targeting " + t if not t.is_empty() else "")
		ActionType.ACTIVATE_ABILITY:
			var text := "%s activates %s" % [who, _card_name(state, card_instance_id)]
			if not label.is_empty():
				text += ": %s" % label
			var t := _describe_targets(state)
			return text + (" targeting " + t if not t.is_empty() else "")
		ActionType.DECLARE_ATTACKERS:
			if attacker_ids.is_empty():
				return "%s does not attack" % who
			var names: PackedStringArray = []
			for id in attacker_ids:
				names.append(_card_name(state, id))
			return "%s attacks with %s" % [who, ", ".join(names)]
		ActionType.DECLARE_BLOCKER:
			return "%s blocks %s with %s" % [who, _card_name(state, blocking_attacker_id), _card_name(state, blocker_id)]
		ActionType.FINISH_COMBAT_DECLARATIONS:
			return "%s finishes declaring blockers" % who
		ActionType.CHOOSE:
			return "%s chooses: %s" % [who, label if not label.is_empty() else str(choice_index)]
	return "%s: unknown action" % who


func _describe_targets(state: MTGGameState) -> String:
	var names: PackedStringArray = []
	for t in targets:
		if t.has("card"):
			names.append(_card_name(state, t["card"]))
		elif t.has("player"):
			names.append("P%d" % t["player"])
	return ", ".join(names)


func _to_string() -> String:
	return "MTGAction(%s)" % signature()


static func _card_name(state: MTGGameState, instance_id: int) -> String:
	var card := state.find_card_instance(instance_id)
	if card and card.definition:
		return card.definition.card_name
	return "card #%d" % instance_id
