class_name BoardView
extends Node3D

## Renders an MTGGameState onto the table: every card gets a CardNode that is
## moved to the cell / pile / hand slot it belongs to. Purely visual — grid
## placement is never part of the game state, which is why AI agents don't have
## to care about it.
##
## Grid layout (rows counted from the human's edge):
##   row 0            human lands
##   rows 1..3        human permanents
##   middle row       the stack
##   rows -4..-2      opponent permanents
##   last row         opponent lands
## The first and last columns are reserved for library / graveyard / exile piles.

@export var grid: BoardGrid
## Scene light, dimmed while the player picks targets (see set_dim).
@export var sun: DirectionalLight3D
@export var dim_light_energy: float = 0.18
@export var card_fill: float = 0.9          # card size as a fraction of a cell
@export var hover_height: float = 0.006     # cards float this far above the board
@export var move_duration: float = 0.35

@export_group("Hands")
@export var hand_distance_cells: float = 0.6   # beyond the board edge, in cell heights
@export var hand_tilt_degrees: float = 32.0    # human hand tilt toward the camera
@export var hand_lift: float = 0.16            # human hand height above the table
@export var hand_hover_lift: float = 0.07
@export var hand_hover_scale: float = 1.35

const COLOR_ATTACKING := Color(1.0, 0.25, 0.2, 0.9)
const COLOR_BLOCKING := Color(0.3, 0.55, 1.0, 0.9)

var human_player: int = 0

var _nodes: Dictionary = {}        # instance_id -> CardNode
var _cells: Dictionary = {}        # instance_id -> Vector2i (battlefield placement)
var _layout: Dictionary = {}       # instance_id -> {"position": Vector3, "basis": Basis, "hand": bool}
var _hovered_id: int = -1
var _spotlit: Array[int] = []
var _sun_energy: float = 1.0
var _dim_tween: Tween
var _cell_markers: Array[MeshInstance3D] = []
var _card_size: Vector2 = Vector2(0.36, 0.504)


func _ready() -> void:
	if grid:
		_card_size = grid.cell_world_size() * card_fill
	if sun:
		_sun_energy = sun.light_energy


## Darkens the table (target-picking mode). Spotlit cards stay bright.
func set_dim(on: bool) -> void:
	if sun == null:
		return
	if _dim_tween and _dim_tween.is_running():
		_dim_tween.kill()
	_dim_tween = create_tween()
	_dim_tween.tween_property(sun, "light_energy", dim_light_energy if on else _sun_energy, 0.25)


## Keeps exactly these cards at full brightness.
func spotlight_cards(ids: Array[int]) -> void:
	for id in _spotlit:
		var node: CardNode = _nodes.get(id)
		if node:
			node.set_spotlight(false)
	_spotlit = ids.duplicate()
	for id in _spotlit:
		var node: CardNode = _nodes.get(id)
		if node:
			node.set_spotlight(true)


func clear_spotlight() -> void:
	spotlight_cards([])


# ───────────────────────────── Public API ─────────────────────────────

## Reserve a battlefield cell for a card (used when the player drops a card on the grid).
func reserve_cell(instance_id: int, cell: Vector2i) -> void:
	_cells[instance_id] = cell


func release_cell(instance_id: int) -> void:
	_cells.erase(instance_id)


func cell_of(instance_id: int) -> Vector2i:
	return _cells.get(instance_id, Vector2i(-1, -1))


func land_row(player_id: int) -> int:
	return 0 if player_id == human_player else grid.rows - 1


func permanent_rows(player_id: int) -> Array[int]:
	var result: Array[int] = []
	var middle := grid.rows / 2
	if player_id == human_player:
		for r in range(1, middle):
			result.append(r)
	else:
		for r in range(grid.rows - 2, middle, -1):
			result.append(r)
	return result


func stack_row() -> int:
	return grid.rows / 2


func pile_column(player_id: int) -> int:
	return 0 if player_id == human_player else grid.columns - 1


## Free cells in the given rows (excluding the pile columns), nearest the centre first.
func free_cells_in_rows(rows: Array[int]) -> Array[Vector2i]:
	var occupied := {}
	for id in _cells.keys():
		occupied[_cells[id]] = true
	var cells: Array[Vector2i] = []
	for row in rows:
		for col in _play_columns():
			var cell := Vector2i(col, row)
			if not occupied.has(cell):
				cells.append(cell)
	return cells


## Cells a card of this type may be dropped on by `player_id`.
func drop_cells_for(card: CardInstance, player_id: int) -> Array[Vector2i]:
	if card.definition and card.definition.card_type == CardDefinition.CardType.LAND:
		return free_cells_in_rows([land_row(player_id)])
	return free_cells_in_rows(permanent_rows(player_id))


func node_for(instance_id: int) -> CardNode:
	return _nodes.get(instance_id)


## Nearest card under a world ray, or null.
func pick_card(origin: Vector3, direction: Vector3) -> CardNode:
	var best: CardNode = null
	var best_dist := INF
	for node: CardNode in _nodes.values():
		var d := node.intersect_ray(origin, direction)
		if d >= 0.0 and d < best_dist:
			best_dist = d
			best = node
	return best


func pick_cell(origin: Vector3, direction: Vector3) -> Vector2i:
	return grid.ray_to_cell(origin, direction)


func highlight_cards(ids: Array[int], color: Color) -> void:
	for id in ids:
		var node: CardNode = _nodes.get(id)
		if node:
			node.set_highlight(color)


func clear_card_highlights() -> void:
	for node: CardNode in _nodes.values():
		node.clear_highlight()


func highlight_cells(cells: Array[Vector2i], color: Color) -> void:
	clear_cell_highlights()
	var size := grid.cell_world_size() * 0.96
	for i in range(cells.size()):
		var marker := _get_cell_marker(i, size)
		(marker.material_override as StandardMaterial3D).albedo_color = color
		marker.global_position = grid.cell_to_world(cells[i]) + grid.up() * 0.003
		marker.global_transform.basis = _flat_basis(human_player, false)
		marker.visible = true


func clear_cell_highlights() -> void:
	for marker in _cell_markers:
		marker.visible = false


## Hover effect for cards in the human's hand.
func set_hovered(node: CardNode) -> void:
	var new_id := node.card_instance.instance_id if node else -1
	if new_id == _hovered_id:
		return
	var old: CardNode = _nodes.get(_hovered_id)
	_hovered_id = new_id
	if old:
		_apply_layout(old)
	if node:
		_apply_layout(node)


## Sync every card node to the state.
func sync(state: MTGGameState) -> void:
	var seen := {}
	var combat_ids := {}

	for player in state.players:
		var pid := player.player_id
		_layout_pile(player.library, pid, 0, false, seen)
		_layout_pile(player.graveyard, pid, 1, true, seen)
		_layout_pile(player.exile, pid, 2, true, seen)
		_layout_hand(player.hand, pid, seen)
		_layout_battlefield(player.battlefield, pid, seen)

	_layout_stack(state.stack, seen)

	# Remove nodes for cards that vanished; free cells of cards that left the battlefield.
	for id in _nodes.keys():
		if not seen.has(id):
			_nodes[id].queue_free()
			_nodes.erase(id)
	for id in _cells.keys():
		var loc := state.find_card_location(id)
		if loc.is_empty() or loc["zone_name"] in ["graveyard", "exile", "library"]:
			_cells.erase(id)

	# Combat highlights
	for id in state.declared_attackers:
		combat_ids[id] = COLOR_ATTACKING
	for id in state.declared_blockers.keys():
		combat_ids[id] = COLOR_BLOCKING
	for id in _nodes.keys():
		var node: CardNode = _nodes[id]
		if combat_ids.has(id):
			node.set_highlight(combat_ids[id])
		else:
			node.clear_highlight()


# ───────────────────────────── Layout ─────────────────────────────

func _play_columns() -> Array[int]:
	# Centre columns first so cards fill the board from the middle outward.
	var cols: Array[int] = []
	var first := 1
	var last := grid.columns - 2
	var centre := (first + last) / 2.0
	for c in range(first, last + 1):
		cols.append(c)
	cols.sort_custom(func(a: int, b: int) -> bool: return absf(a - centre) < absf(b - centre))
	return cols


func _layout_battlefield(cards: Array[CardInstance], pid: int, seen: Dictionary) -> void:
	# Cards with a reserved cell first so auto-placed cards never steal it.
	var pending: Array[CardInstance] = []
	for card in cards:
		seen[card.instance_id] = true
		if not _cells.has(card.instance_id):
			pending.append(card)
	for card in pending:
		var candidates := drop_cells_for(card, pid)
		if candidates.is_empty():
			candidates = free_cells_in_rows(range_rows(pid))
		_cells[card.instance_id] = candidates[0] if not candidates.is_empty() else Vector2i(pile_column(pid), land_row(pid))

	for card in cards:
		var node := _get_or_create(card)
		node.set_face_up(true)
		var cell: Vector2i = _cells[card.instance_id]
		_set_layout(node, grid.cell_to_world(cell) + grid.up() * hover_height, _flat_basis(pid, card.tapped), false)


func range_rows(pid: int) -> Array[int]:
	var rows: Array[int] = [land_row(pid)]
	rows.append_array(permanent_rows(pid))
	return rows


func _layout_pile(cards: Array[CardInstance], pid: int, slot: int, face_up: bool, seen: Dictionary) -> void:
	var row := land_row(pid) + (slot if pid == human_player else -slot)
	var base := grid.cell_to_world(Vector2i(pile_column(pid), row))
	var up := grid.up()
	for i in range(cards.size()):
		var card := cards[i]
		seen[card.instance_id] = true
		var node := _get_or_create(card)
		node.set_face_up(face_up)
		var basis := _flat_basis(pid, false)
		if not face_up:
			basis = basis * Basis(Vector3.UP, PI) # flip: back on top
		_set_layout(node, base + up * (hover_height + i * 0.0025), basis, false)


func _layout_hand(cards: Array[CardInstance], pid: int, seen: Dictionary) -> void:
	var is_human := pid == human_player
	var centre := grid.edge_point(not is_human, hand_distance_cells)
	var up := grid.up()
	var right := grid.right()      # increasing columns
	var forward := grid.forward()  # toward the opponent
	var n := cards.size()

	var max_width := grid.cell_world_size().x * (grid.columns - 2)
	var spacing := _card_size.x * 1.08
	if n > 1:
		spacing = minf(spacing, max_width / n)

	var basis: Basis
	var origin: Vector3
	var spread_dir: Vector3
	if is_human:
		# Tilted toward the player, lifted so the lower edge clears the table.
		var t := deg_to_rad(hand_tilt_degrees)
		basis = Basis(-right, forward * cos(t) + up * sin(t), up * cos(t) - forward * sin(t))
		origin = centre + up * hand_lift
		spread_dir = -right # left-to-right as seen by the player
	else:
		basis = _flat_basis(pid, false) * Basis(Vector3.UP, PI) # face down
		origin = centre + up * hover_height
		spread_dir = right

	for i in range(n):
		var card := cards[i]
		seen[card.instance_id] = true
		var node := _get_or_create(card)
		node.set_face_up(is_human)
		var offset := (i - (n - 1) * 0.5) * spacing
		var pos := origin + spread_dir * offset
		if is_human:
			pos += up * (i * 0.0015) # slight stagger so overlapping cards sort cleanly
		_set_layout(node, pos, basis, is_human)


func _layout_stack(stack: Array[Dictionary], seen: Dictionary) -> void:
	var row := stack_row()
	var n := stack.size()
	var first_col := grid.columns / 2 - n / 2
	for i in range(n):
		var card: CardInstance = stack[i]["card"]
		var controller: int = stack[i]["controller"]
		seen[card.instance_id] = true
		var node := _get_or_create(card)
		node.set_face_up(true)
		var col := clampi(first_col + i, 1, grid.columns - 2)
		var pos := grid.cell_to_world(Vector2i(col, row)) + grid.up() * (hover_height + i * 0.004)
		_set_layout(node, pos, _flat_basis(controller, false), false)


## Flat on the board, face up, top of the card pointing away from its owner.
func _flat_basis(pid: int, tapped: bool) -> Basis:
	var up := grid.up()
	var right := grid.right()
	var forward := grid.forward()
	var basis: Basis
	if pid == human_player:
		basis = Basis(-right, forward, up)
	else:
		basis = Basis(right, -forward, up)
	if tapped:
		basis = basis * Basis(Vector3(0, 0, 1), -PI * 0.5)
	return basis


func _set_layout(node: CardNode, pos: Vector3, basis: Basis, in_hand: bool) -> void:
	_layout[node.card_instance.instance_id] = {"position": pos, "basis": basis, "hand": in_hand}
	_apply_layout(node)


func _apply_layout(node: CardNode) -> void:
	var id := node.card_instance.instance_id
	if not _layout.has(id):
		return
	var entry: Dictionary = _layout[id]
	var pos: Vector3 = entry["position"]
	var basis: Basis = entry["basis"]
	if id == _hovered_id and entry["hand"]:
		pos += basis.z.normalized() * hand_hover_lift
		node.set_scale_factor(hand_hover_scale)
	else:
		node.set_scale_factor(1.0)
	node.move_to(pos, basis, move_duration)
	node.refresh()


func _get_or_create(card: CardInstance) -> CardNode:
	if _nodes.has(card.instance_id):
		var existing: CardNode = _nodes[card.instance_id]
		existing.card_instance = card # states are deep copies; keep the latest instance
		return existing
	var node := CardNode.new(card, _card_size)
	add_child(node)
	# New cards appear from their pile position instead of popping in at the origin.
	node.global_position = grid.cell_to_world(Vector2i(pile_column(card.owner_id), land_row(card.owner_id)))
	node.global_transform.basis = _flat_basis(card.owner_id, false)
	_nodes[card.instance_id] = node
	return node


func _get_cell_marker(index: int, size: Vector2) -> MeshInstance3D:
	while _cell_markers.size() <= index:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var mesh := QuadMesh.new()
		mesh.size = size
		var marker := MeshInstance3D.new()
		marker.mesh = mesh
		marker.material_override = mat
		marker.visible = false
		add_child(marker)
		_cell_markers.append(marker)
	var marker := _cell_markers[index]
	(marker.mesh as QuadMesh).size = size
	return marker
