extends Node3D
class_name CameraRig

@export var move_speed := 12.0
@export var zoom_speed := 2.5
@export var min_height := 6.0
@export var max_height := 40.0
@export var orbit_sensitivity := 0.25

var _dragging := false
var _yaw := 0.0


func _ready() -> void:
	_yaw = rotation_degrees.y


func _process(delta: float) -> void:
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
		var local_move := transform.basis * input.normalized()
		local_move.y = 0.0
		position += local_move.normalized() * move_speed * delta


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(-zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(zoom_speed)
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * orbit_sensitivity
		rotation_degrees.y = _yaw


func _zoom(amount: float) -> void:
	var camera := get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	camera.position.y = clampf(camera.position.y + amount, min_height, max_height)
	camera.position.z = clampf(camera.position.z + amount * 0.8, 8.0, 48.0)
