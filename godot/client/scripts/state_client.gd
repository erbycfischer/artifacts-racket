extends Node
class_name StateClient

signal message_received(message: Dictionary)
signal status_changed(status: String)

@export var websocket_url := "ws://127.0.0.1:8787"
@export var reconnect_seconds := 3.0

var _socket := WebSocketPeer.new()
var _reconnect_timer := 0.0
var _started := false


func connect_to_server() -> void:
	_started = true
	_reconnect_timer = 0.0
	_socket = WebSocketPeer.new()
	var error := _socket.connect_to_url(websocket_url)
	if error != OK:
		status_changed.emit("websocket error: %s" % error_string(error))
		_reconnect_timer = reconnect_seconds
	else:
		status_changed.emit("connecting to %s" % websocket_url)


func send_command(command: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	var payload := JSON.stringify(command)
	_socket.send_text(payload)


func _process(delta: float) -> void:
	if not _started:
		return

	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			connect_to_server()
		return

	_socket.poll()
	var state := _socket.get_ready_state()
	match state:
		WebSocketPeer.STATE_CONNECTING:
			return
		WebSocketPeer.STATE_OPEN:
			_read_packets()
		WebSocketPeer.STATE_CLOSING:
			return
		WebSocketPeer.STATE_CLOSED:
			status_changed.emit("websocket closed; retrying")
			_reconnect_timer = reconnect_seconds


func _read_packets() -> void:
	status_changed.emit("connected to %s" % websocket_url)
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if parsed is Dictionary:
			message_received.emit(parsed)
		else:
			push_warning("Ignored non-dictionary websocket packet.")
