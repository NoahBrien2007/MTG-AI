class_name TableCamera
extends Camera3D

## Free-look table camera.
##   Right mouse drag  – look around
##   W/A/S/D           – move, E/Q – up/down
##   Mouse wheel       – zoom (dolly)
##   R                 – reset to the starting view

@export var move_speed: float = 6.0
@export var look_sensitivity: float = 0.003
@export var zoom_step: float = 0.4

var _looking: bool = false
var _yaw: float = 0.0
var _pitch: float = 0.0
var _home: Transform3D


func _ready() -> void:
	_home = global_transform
	_yaw = rotation.y
	_pitch = rotation.x


func reset_view() -> void:
	global_transform = _home
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_looking = event.pressed
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					global_position -= global_transform.basis.z * zoom_step
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					global_position += global_transform.basis.z * zoom_step

	elif event is InputEventMouseMotion and _looking:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(_pitch, _yaw, 0.0)

	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		reset_view()


func _process(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		move += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		move -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		move += transform.basis.x
	if Input.is_key_pressed(KEY_E):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		move += Vector3.DOWN
	if move.length_squared() > 0.0:
		global_position += move.normalized() * move_speed * delta
