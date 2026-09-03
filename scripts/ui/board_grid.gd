class_name BoardGrid
extends MeshInstance3D

## The playfield quad with the card-slot grid shader. Owns the mapping between
## grid cells (column, row) and world positions, and fades the grid in on hover.
##
## Row 0 is the edge nearest the human player (local -Z), the last row is the
## opponent's edge. Column 0 is at local -X.

@export var columns: int = 20
@export var fade_duration: float = 0.3

## Derived from the quad size and the column count so the cells match the shader.
var rows: int = 1
var board_size: Vector2 = Vector2(1.6, 1.0)  # local (unscaled) units
var cell_size: Vector2 = Vector2(0.08, 0.112)

var _mat: ShaderMaterial
var _tween: Tween
var _hovered: bool = false
var _forced: bool = false


func _ready() -> void:
	var quad := mesh as QuadMesh
	if quad:
		board_size = quad.size

	columns = max(columns, 1)
	cell_size.x = board_size.x / columns
	cell_size.y = cell_size.x * 1.4 # MTG card ratio, same as the shader
	rows = max(1, int(floor(board_size.y / cell_size.y + 0.001)))

	if material_override is ShaderMaterial:
		_mat = (material_override as ShaderMaterial).duplicate()
		material_override = _mat
	elif mesh and mesh.surface_get_material(0) is ShaderMaterial:
		_mat = mesh.surface_get_material(0).duplicate()
		material_override = _mat

	if _mat:
		_mat.set_shader_parameter("board_dimensions", board_size)
		_mat.set_shader_parameter("card_scale", cell_size.x)
		_mat.set_shader_parameter("hover_alpha", 0.0)


# ───────────────────────────── Geometry ─────────────────────────────

func is_valid_cell(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < columns and cell.y >= 0 and cell.y < rows


func cell_to_local(cell: Vector2i) -> Vector3:
	return Vector3(
		-board_size.x * 0.5 + (cell.x + 0.5) * cell_size.x,
		0.0,
		-board_size.y * 0.5 + (cell.y + 0.5) * cell_size.y
	)


func cell_to_world(cell: Vector2i) -> Vector3:
	return global_transform * cell_to_local(cell)


func local_to_world(local: Vector3) -> Vector3:
	return global_transform * local


## Size of one cell in world units.
func cell_world_size() -> Vector2:
	var s := global_transform.basis.get_scale()
	return Vector2(cell_size.x * s.x, cell_size.y * s.z)


## Board normal in world space.
func up() -> Vector3:
	return global_transform.basis.y.normalized()


## World direction along increasing columns.
func right() -> Vector3:
	return global_transform.basis.x.normalized()


## World direction along increasing rows (toward the opponent).
func forward() -> Vector3:
	return global_transform.basis.z.normalized()


## World point on the near (human) or far (opponent) edge, `distance_cells` cell
## heights beyond the board.
func edge_point(far_side: bool, distance_cells: float) -> Vector3:
	var z := board_size.y * 0.5 + distance_cells * cell_size.y
	return local_to_world(Vector3(0.0, 0.0, z if far_side else -z))


## Intersects a world-space ray with the board plane. Returns the cell hit, or
## Vector2i(-1, -1) if the ray misses the board.
func ray_to_cell(origin: Vector3, direction: Vector3) -> Vector2i:
	var plane := Plane(up(), global_position)
	var hit = plane.intersects_ray(origin, direction)
	if hit == null:
		return Vector2i(-1, -1)
	var local: Vector3 = global_transform.affine_inverse() * (hit as Vector3)
	var col := int(floor((local.x + board_size.x * 0.5) / cell_size.x))
	var row := int(floor((local.z + board_size.y * 0.5) / cell_size.y))
	var cell := Vector2i(col, row)
	return cell if is_valid_cell(cell) else Vector2i(-1, -1)


# ───────────────────────────── Grid visibility ─────────────────────────────

func on_hover_enter() -> void:
	_hovered = true
	_update_alpha()


func on_hover_exit() -> void:
	_hovered = false
	_update_alpha()


## Keep the grid visible regardless of hover (used while placing a card).
func set_forced_visible(forced: bool) -> void:
	_forced = forced
	_update_alpha()


func _update_alpha() -> void:
	if not _mat:
		return
	var target := 1.0 if (_hovered or _forced) else 0.0
	if _tween and _tween.is_running():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_mat, "shader_parameter/hover_alpha", target, fade_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
