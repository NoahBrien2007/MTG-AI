class_name CardNode
extends Node3D

## 3D representation of one CardInstance. Built entirely in code.
##
## Local frame: +Z is the face normal, +Y points to the top of the card,
## +X to the right of the card (as read). BoardView decides the orientation.

const THICKNESS := 0.004
const FRAME_MARGIN := 1.06

var card_instance: CardInstance
var face_up: bool = true
var size: Vector2 = Vector2(0.36, 0.504)

var _face: MeshInstance3D
var _back: MeshInstance3D
var _frame: MeshInstance3D
var _name_label: Label3D
var _type_label: Label3D
var _pt_label: Label3D

var _face_mat: StandardMaterial3D
var _frame_mat: StandardMaterial3D

var _texture_requested: bool = false
var _has_texture: bool = false
var _move_tween: Tween
var _scale_tween: Tween


func _init(instance: CardInstance = null, card_size: Vector2 = Vector2(0.36, 0.504)) -> void:
	card_instance = instance
	size = card_size


func _ready() -> void:
	_build()
	refresh()


func _build() -> void:
	_face_mat = StandardMaterial3D.new()
	_face_mat.albedo_color = Color(0.86, 0.84, 0.78)
	_face_mat.roughness = 0.6

	var face_mesh := QuadMesh.new()
	face_mesh.size = size
	_face = MeshInstance3D.new()
	_face.mesh = face_mesh
	_face.material_override = _face_mat
	_face.position = Vector3(0, 0, THICKNESS * 0.5)
	add_child(_face)

	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.32, 0.18, 0.1)
	back_mat.roughness = 0.7
	var back_mesh := QuadMesh.new()
	back_mesh.size = size
	_back = MeshInstance3D.new()
	_back.mesh = back_mesh
	_back.material_override = back_mat
	_back.position = Vector3(0, 0, -THICKNESS * 0.5)
	_back.rotation_degrees = Vector3(0, 180, 0)
	add_child(_back)

	_frame_mat = StandardMaterial3D.new()
	_frame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_frame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_frame_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_frame_mat.albedo_color = Color(1, 1, 0, 0.85)
	var frame_mesh := QuadMesh.new()
	frame_mesh.size = size * FRAME_MARGIN
	_frame = MeshInstance3D.new()
	_frame.mesh = frame_mesh
	_frame.material_override = _frame_mat
	_frame.position = Vector3(0, 0, -THICKNESS)
	_frame.visible = false
	add_child(_frame)

	var px := size.x / 420.0 # world units per "pixel" — a card face is ~420 px wide
	_name_label = _make_label(px, 30, Color(0.1, 0.1, 0.1))
	_name_label.position = Vector3(0, size.y * 0.36, THICKNESS)
	_type_label = _make_label(px, 22, Color(0.25, 0.25, 0.3))
	_type_label.position = Vector3(0, -size.y * 0.05, THICKNESS)
	_pt_label = _make_label(px, 40, Color(0.1, 0.1, 0.1))
	_pt_label.position = Vector3(size.x * 0.3, -size.y * 0.4, THICKNESS)


func _make_label(px: float, font_size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.pixel_size = px
	label.font_size = font_size
	label.outline_size = 0
	label.modulate = color
	label.width = size.x / px * 0.9
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.no_depth_test = false
	add_child(label)
	return label


## Re-read the card instance (power/toughness bonuses, damage…) and refresh the face.
func refresh() -> void:
	if not card_instance or not card_instance.definition or not _name_label:
		return
	var def := card_instance.definition
	_name_label.text = def.card_name
	_type_label.text = def.type_line if not def.type_line.is_empty() else def.type_name()
	if card_instance.is_creature():
		_pt_label.text = "%d/%d" % [card_instance.get_power(), card_instance.get_toughness()]
		if card_instance.damage_marked > 0:
			_pt_label.modulate = Color(0.75, 0.1, 0.1)
		else:
			_pt_label.modulate = Color(0.1, 0.1, 0.1)
		_pt_label.visible = true
	else:
		_pt_label.visible = false
	_update_text_visibility()
	if face_up:
		_request_texture()


func set_face_up(value: bool) -> void:
	face_up = value
	if face_up:
		_request_texture()
	_update_text_visibility()


func set_highlight(color: Color, on: bool = true) -> void:
	if not _frame:
		return
	_frame.visible = on
	_frame_mat.albedo_color = color


## Spotlit cards ignore scene lighting, so they stay bright while the table is dimmed.
func set_spotlight(on: bool) -> void:
	if _face_mat:
		_face_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if on else BaseMaterial3D.SHADING_MODE_PER_PIXEL


func clear_highlight() -> void:
	if _frame:
		_frame.visible = false


func is_highlighted() -> bool:
	return _frame != null and _frame.visible


## Smoothly move/rotate to a world transform.
func move_to(target_position: Vector3, target_basis: Basis, duration: float = 0.35) -> void:
	if _move_tween and _move_tween.is_running():
		_move_tween.kill()
	var target_quat := Quaternion(target_basis.orthonormalized())
	if duration <= 0.0:
		global_position = target_position
		quaternion = target_quat
		return
	_move_tween = create_tween().set_parallel(true)
	_move_tween.tween_property(self, "global_position", target_position, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_move_tween.tween_property(self, "quaternion", target_quat, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func set_scale_factor(factor: float, duration: float = 0.15) -> void:
	if _scale_tween and _scale_tween.is_running():
		_scale_tween.kill()
	_scale_tween = create_tween()
	_scale_tween.tween_property(self, "scale", Vector3.ONE * factor, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Distance along the ray to this card's face, or -1.0 if the ray misses it.
func intersect_ray(origin: Vector3, direction: Vector3) -> float:
	var normal := global_transform.basis.z.normalized()
	var plane := Plane(normal, global_position)
	var hit = plane.intersects_ray(origin, direction)
	if hit == null:
		# Try the back side as well (face-down cards)
		hit = Plane(-normal, global_position).intersects_ray(origin, direction)
		if hit == null:
			return -1.0
	var local := to_local(hit as Vector3)
	if absf(local.x) <= size.x * 0.5 and absf(local.y) <= size.y * 0.5:
		return origin.distance_to(hit as Vector3)
	return -1.0


func _request_texture() -> void:
	if _texture_requested or not card_instance or not card_instance.definition:
		return
	_texture_requested = true
	CardTextures.fetch(card_instance.definition.card_name, _on_texture_ready)


func _on_texture_ready(texture: Texture2D) -> void:
	if not is_instance_valid(self) or texture == null:
		return
	_has_texture = true
	_face_mat.albedo_texture = texture
	_face_mat.albedo_color = Color.WHITE
	_update_text_visibility()


func _update_text_visibility() -> void:
	# Text is a fallback while there is no artwork; hide it once the real card shows.
	var show := not _has_texture
	if _name_label:
		_name_label.visible = show
		_type_label.visible = show
		_pt_label.visible = show and card_instance != null and card_instance.definition != null \
			and card_instance.is_creature()
