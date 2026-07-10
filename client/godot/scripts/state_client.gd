extends Node
class_name StateClient

signal message_received(message: Dictionary)
signal status_changed(status: String)

@export var websocket_url := "ws://127.0.0.1:8787"
@export var reconnect_seconds := 3.0
@export var reconnect_max_seconds := 30.0

var _socket := WebSocketPeer.new()
var _reconnect_timer := 0.0
var _reconnect_delay := 3.0
var _started := false
var _was_open := false
var _last_status := ""
var _auto_reconnect := true


func set_websocket_url(url: String) -> void:
	websocket_url = url


func connect_to_server() -> void:
	_started = true
	_auto_reconnect = true
	_was_open = false
	_reconnect_timer = 0.0
	_socket = WebSocketPeer.new()
	var error := _socket.connect_to_url(websocket_url)
	if error != OK:
		_emit_status("websocket error: %s" % error_string(error))
		_schedule_reconnect()
	else:
		_emit_status("connecting to %s" % websocket_url)


func disconnect_from_server() -> void:
	_auto_reconnect = false
	_started = false
	_reconnect_timer = 0.0
	_was_open = false
	if _socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_socket.close()
	_emit_status("disconnected")


func is_connected_to_hub() -> bool:
	return _socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func send_command(command: Dictionary) -> bool:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_emit_status("cannot send; not connected")
		return false
	var payload := JSON.stringify(command)
	_socket.send_text(payload)
	return true


func _process(delta: float) -> void:
	if not _started:
		return

	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0 and _auto_reconnect:
			connect_to_server()
		return

	_socket.poll()
	var state := _socket.get_ready_state()
	match state:
		WebSocketPeer.STATE_CONNECTING:
			return
		WebSocketPeer.STATE_OPEN:
			if not _was_open:
				_was_open = true
				_reconnect_delay = reconnect_seconds
				_emit_status("connected to %s" % websocket_url)
			_read_packets()
		WebSocketPeer.STATE_CLOSING:
			return
		WebSocketPeer.STATE_CLOSED:
			_was_open = false
			if _auto_reconnect:
				_emit_status("websocket closed; retrying in %.0fs" % _reconnect_delay)
				_schedule_reconnect()
			else:
				_emit_status("disconnected")


func _schedule_reconnect() -> void:
	if not _auto_reconnect:
		return
	_reconnect_timer = _reconnect_delay
	_reconnect_delay = minf(_reconnect_delay * 2.0, reconnect_max_seconds)


func _read_packets() -> void:
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if parsed is Dictionary:
			message_received.emit(parsed)
		else:
			push_warning("Ignored non-dictionary websocket packet.")


func _emit_status(status: String) -> void:
	if status == _last_status:
		return
	_last_status = status
	status_changed.emit(status)
