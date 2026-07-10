extends Node3D
class_name CameraRig

@export var move_speed := 14.0
@export var zoom_speed := 2.2
@export var min_height := 7.0
@export var max_height := 48.0
@export var orbit_sensitivity := 0.28
@export var pitch_sensitivity := 0.18
@export var follow_lerp := 7.0
@export var tile_size := 2.0
@export var min_pitch := -58.0
@export var max_pitch := -32.0

var _dragging := false
var _yaw := 28.0
var _pitch := -46.0
var _follow_enabled := false
var _follow_target := Vector3.ZERO


func _ready() -> void:
	rotation_degrees = Vector3(_pitch, _yaw, 0.0)
	var camera := get_node_or_null("Camera3D") as Camera3D
	if camera:
		# Keep camera offset cinematic; look toward rig origin.
		camera.look_at(global_position + Vector3(0, 0.5, 0), Vector3.UP)


func set_follow_target(world_position: Vector3, enabled: bool = true) -> void:
	_follow_target = world_position
	_follow_enabled = enabled


func clear_follow() -> void:
	_follow_enabled = false


func _process(delta: float) -> void:
	if _follow_enabled:
		var flat_target := Vector3(_follow_target.x, position.y, _follow_target.z)
		position = position.lerp(flat_target, clampf(follow_lerp * delta, 0.0, 1.0))

	var input := Vector3.ZERO
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		input.z += 1.0

	if input != Vector3.ZERO:
		_follow_enabled = false
		var local_move := transform.basis * input.normalized()
		local_move.y = 0.0
		if local_move.length_squared() > 0.0001:
			position += local_move.normalized() * move_speed * delta

	rotation_degrees = Vector3(_pitch, _yaw, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(-zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(zoom_speed)
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * orbit_sensitivity
		_pitch -= event.relative.y * pitch_sensitivity
		_pitch = clampf(_pitch, min_pitch, max_pitch)


func _zoom(amount: float) -> void:
	var camera := get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	camera.position.y = clampf(camera.position.y + amount, min_height, max_height)
	camera.position.z = clampf(camera.position.z + amount * 0.85, 10.0, 52.0)
