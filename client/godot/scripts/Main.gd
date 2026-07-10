extends Node3D

const FIXTURE_PATHS: Array[String] = [
	"res://fixtures/world_snapshot.json",
	"res://fixtures/bot_decision.json",
	"res://fixtures/market_signal.json",
]
const SETTINGS_PATH := "user://settings.cfg"

@onready var visual_state: Node = $VisualState
@onready var state_client: Node = $StateClient
@onready var map_renderer: Node3D = $WorldRoot/MapRenderer
@onready var marker_renderer: Node3D = $WorldRoot/MarkerRenderer
@onready var camera_rig: Node3D = $CameraRig
@onready var ui_root: CanvasLayer = $UIRoot

var _live_connected := false
var _saw_live_message := false
var _fixtures_only := false
var _follow_character := true


func _ready() -> void:
	_connect_signals()
	_load_settings()
	_load_fixture_messages()
	if not _fixtures_only:
		state_client.call("connect_to_server")
	else:
		ui_root.call("set_mode", "Offline", "fixtures only")
		ui_root.call("set_status", "fixtures only; hub disabled")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_request_action("rest", {})
		elif event.keycode == KEY_F:
			_follow_character = true
			_follow_selected_character()
		elif event.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
			# WASD / arrows pan: clear follow so camera stays under player control.
			_follow_character = false
			if camera_rig.has_method("clear_follow"):
				camera_rig.call("clear_follow")


func _connect_signals() -> void:
	state_client.status_changed.connect(_on_client_status)
	state_client.message_received.connect(_on_protocol_message)
	visual_state.world_snapshot_updated.connect(_on_world_snapshot_updated)
	visual_state.bot_decision_received.connect(_on_overlay_state_changed)
	visual_state.market_signal_received.connect(_on_overlay_state_changed)
	visual_state.session_status_received.connect(_on_session_status)
	visual_state.action_result_received.connect(_on_action_result)
	visual_state.account_logs_received.connect(_on_account_logs)
	visual_state.selection_changed.connect(ui_root.set_selected_tile)
	visual_state.selection_changed.connect(func(tile: Dictionary) -> void:
		map_renderer.call("set_selected_tile", tile)
	)
	visual_state.selected_character_changed.connect(_on_character_selected)
	map_renderer.tile_selected.connect(visual_state.select_tile)
	ui_root.overlay_changed.connect(_on_overlay_changed)
	ui_root.connect_requested.connect(_on_connect_requested)
	ui_root.disconnect_requested.connect(_on_disconnect_requested)
	ui_root.auth_requested.connect(_on_auth_requested)
	ui_root.logout_requested.connect(_on_logout_requested)
	ui_root.character_selected.connect(_on_ui_character_selected)
	ui_root.action_requested.connect(_on_action_requested)
	ui_root.fixtures_only_toggled.connect(_on_fixtures_only_toggled)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	var url := str(cfg.get_value("connection", "websocket_url", "ws://127.0.0.1:8787"))
	_fixtures_only = bool(cfg.get_value("connection", "fixtures_only", false))
	state_client.call("set_websocket_url", url)
	ui_root.call("set_host_url", url)
	if ui_root.has_method("set_fixtures_only"):
		ui_root.call("set_fixtures_only", _fixtures_only)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("connection", "websocket_url", ui_root.call("get_host_url"))
	cfg.set_value("connection", "fixtures_only", _fixtures_only)
	cfg.save(SETTINGS_PATH)


func _load_fixture_messages() -> void:
	for path in FIXTURE_PATHS:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_warning("Missing visualizer fixture: %s" % path)
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			visual_state.call("apply_message", parsed)
		else:
			push_warning("Fixture did not contain a protocol message: %s" % path)

	_live_connected = false
	_saw_live_message = false
	ui_root.call("set_mode", "Offline", "fixtures; waiting for hub")
	ui_root.call("set_status", "offline fixtures loaded")


func _on_client_status(status: String) -> void:
	ui_root.call("set_status", status)
	var lower := status.to_lower()
	if lower.begins_with("connected"):
		_live_connected = true
		state_client.call("send_command", {"type": "ui.subscribe", "data": {}})
		if _saw_live_message:
			ui_root.call("set_mode", "Live", "hub streaming")
		else:
			ui_root.call("set_mode", "Connected", "waiting for first snapshot")
	elif "closed" in lower or "retrying" in lower or "error" in lower:
		_live_connected = false
		if _saw_live_message:
			ui_root.call("set_mode", "Reconnecting", "last live data kept")
		else:
			ui_root.call("set_mode", "Offline", "fixtures; hub unavailable")
	elif "disconnected" in lower:
		_live_connected = false
		ui_root.call("set_mode", "Offline", "disconnected")


func _on_protocol_message(message: Dictionary) -> void:
	var message_type := str(message.get("type", ""))
	if message_type == "world.snapshot" and not _saw_live_message:
		# Replace fixture world with first live snapshot.
		visual_state.call("clear_live_overlays")
	_saw_live_message = true
	if _live_connected:
		var status: Variant = visual_state.get("session_status")
		var authenticated := status is Dictionary and bool(status.get("authenticated", false))
		if authenticated:
			ui_root.call("set_mode", "Playing", "official session live")
		else:
			ui_root.call("set_mode", "Unauthenticated", "hub live; auth to play")
	visual_state.call("apply_message", message)


func _on_world_snapshot_updated() -> void:
	map_renderer.call("render_world", visual_state.get("maps"))
	marker_renderer.call("render_state", visual_state)
	ui_root.call("set_world_summary", visual_state.get("maps").size(), visual_state.get("characters").size())
	ui_root.call("set_characters_from_snapshot", visual_state.get("characters"))
	_follow_selected_character()


func _on_overlay_state_changed(_payload: Dictionary) -> void:
	marker_renderer.call("render_state", visual_state)
	ui_root.call("set_decisions", visual_state.get("latest_decisions"))
	ui_root.call("set_market_signals", visual_state.get("market_signals"))


func _on_session_status(status: Dictionary) -> void:
	ui_root.call("set_session_status", status)


func _on_action_result(result: Dictionary) -> void:
	ui_root.call("set_action_result", result)


func _on_account_logs(entries: Array) -> void:
	ui_root.call("set_account_logs", entries)


func _on_character_selected(character_name: String) -> void:
	# Keep bridge selection in sync when VisualState auto-picks first character.
	if _live_connected and not character_name.is_empty():
		state_client.call("send_command", {
			"type": "player.select",
			"data": {"character": character_name},
		})
	_follow_selected_character()


func _on_ui_character_selected(character_name: String) -> void:
	_follow_character = true
	visual_state.call("select_character", character_name)
	# player.select is sent from _on_character_selected to avoid duplicates
	ui_root.call("set_characters_from_snapshot", visual_state.get("characters"))


func _on_connect_requested(url: String) -> void:
	_fixtures_only = false
	state_client.call("set_websocket_url", url)
	_save_settings()
	state_client.call("connect_to_server")


func _on_disconnect_requested() -> void:
	state_client.call("disconnect_from_server")
	_save_settings()


func _on_auth_requested(token: String) -> void:
	state_client.call("send_command", {
		"type": "session.auth",
		"data": {"token": token},
	})


func _on_logout_requested() -> void:
	state_client.call("send_command", {"type": "session.logout", "data": {}})
	visual_state.set("session_status", {})
	visual_state.set("selected_character", "")
	visual_state.set("last_action_result", {})
	visual_state.set("account_logs", [])
	ui_root.call("set_session_status", {"authenticated": false, "selected": "", "characters": [], "error": null})
	ui_root.call("set_mode", "Unauthenticated", "logged out")
	ui_root.call("set_characters_from_snapshot", visual_state.get("characters"))


func _on_action_requested(action_name: String, payload: Dictionary) -> void:
	_request_action(action_name, payload)


func _request_action(action_name: String, payload: Dictionary) -> void:
	var character_name := str(visual_state.get("selected_character"))
	if character_name.is_empty():
		ui_root.call("set_action_result", {"ok": false, "character": "", "action": action_name, "message": "select a character"})
		return
	state_client.call("send_command", {
		"type": "player.action",
		"data": {
			"character": character_name,
			"action": action_name,
			"payload": payload,
		},
	})


func _on_fixtures_only_toggled(enabled: bool) -> void:
	_fixtures_only = enabled
	_save_settings()
	if enabled:
		state_client.call("disconnect_from_server")
		_load_fixture_messages()
		ui_root.call("set_mode", "Offline", "fixtures only")
	else:
		state_client.call("connect_to_server")


func _follow_selected_character() -> void:
	if not _follow_character:
		return
	var character_name := str(visual_state.get("selected_character"))
	var character: Dictionary = visual_state.call("find_character", character_name)
	if character.is_empty():
		return
	var tile_size: float = map_renderer.get("tile_size")
	var world_pos := Vector3(
		float(character.get("x", 0)) * tile_size,
		0.0,
		float(character.get("y", 0)) * tile_size
	)
	camera_rig.call("set_follow_target", world_pos, true)


func _on_overlay_changed(overlay_name: String, enabled: bool) -> void:
	match overlay_name:
		"routes":
			marker_renderer.set("show_routes", enabled)
		"market":
			marker_renderer.set("show_market_signals", enabled)
		"labels":
			map_renderer.set("show_labels", enabled)
			map_renderer.call("render_world", visual_state.get("maps"))
		_:
			return
	marker_renderer.call("render_state", visual_state)
