extends CanvasLayer
class_name VisualizerUI

signal overlay_changed(overlay_name: String, enabled: bool)
signal connect_requested(url: String)
signal disconnect_requested
signal auth_requested(token: String)
signal logout_requested
signal character_selected(character_name: String)
signal action_requested(action_name: String, payload: Dictionary)
signal fixtures_only_toggled(enabled: bool)

var _mode_label: Label
var _status_label: Label
var _summary_label: Label
var _selection_label: Label
var _session_label: Label
var _hud_label: Label
var _action_label: Label
var _decisions_label: Label
var _market_label: Label
var _logs_label: Label
var _character_option: OptionButton
var _host_edit: LineEdit
var _token_edit: LineEdit
var _fixtures_only: CheckButton
var _routes_toggle: CheckButton
var _market_toggle: CheckButton
var _labels_toggle: CheckButton
var _move_btn: Button
var _fight_btn: Button
var _gather_btn: Button
var _rest_btn: Button
var _bank_deposit_btn: Button
var _bank_withdraw_btn: Button
var _ge_scan_btn: Button

var _selected_tile: Dictionary = {}
var _selected_character: String = ""
var _characters_cooling: Dictionary = {}


func _ready() -> void:
	_build_ui()


func set_mode(mode: String, detail: String = "") -> void:
	if _mode_label == null:
		return
	if detail.is_empty():
		_mode_label.text = "Mode: %s" % mode
	else:
		_mode_label.text = "Mode: %s — %s" % [mode, detail]


func set_status(status: String) -> void:
	if _status_label:
		_status_label.text = "Status: %s" % status


func set_world_summary(map_count: int, character_count: int) -> void:
	if _summary_label:
		_summary_label.text = "Maps: %d | Characters: %d" % [map_count, character_count]


func set_selected_tile(tile: Dictionary) -> void:
	_selected_tile = tile
	if _selection_label == null:
		return
	if tile.is_empty():
		_selection_label.text = "Selected: none"
		_update_action_buttons()
		return

	var content_type := str(tile.get("content_type", ""))
	var content_code := str(tile.get("content_code", ""))
	var interactions: Variant = tile.get("interactions", {})
	if content_type.is_empty() and interactions is Dictionary:
		var content: Variant = interactions.get("content", {})
		if content is Dictionary:
			content_type = str(content.get("type", "terrain"))
			content_code = str(content.get("code", ""))

	_selection_label.text = "Selected: %s (%s,%s) %s/%s" % [
		tile.get("layer", "overworld"),
		tile.get("x", 0),
		tile.get("y", 0),
		content_type if not content_type.is_empty() else "terrain",
		content_code if not content_code.is_empty() else "-",
	]
	_update_action_buttons()


func set_session_status(status: Dictionary) -> void:
	if _session_label == null:
		return
	var authenticated := bool(status.get("authenticated", false))
	var selected := str(status.get("selected", ""))
	var err := str(status.get("error", ""))
	var chars: Array = status.get("characters", [])
	_refresh_character_options(chars, selected)
	var pending := int(status.get("pending_items", 0))
	var text := "Session: %s" % ("authenticated" if authenticated else "unauthenticated")
	if not selected.is_empty():
		text += " | selected %s" % selected
	if pending > 0:
		text += " | pending %d" % pending
	if not err.is_empty() and err != "Null" and err != "<null>":
		text += " | error: %s" % err
	_session_label.text = text
	if authenticated:
		set_mode("Playing" if not selected.is_empty() else "Authenticated", "manual actions enabled")


func set_action_result(result: Dictionary) -> void:
	if _action_label == null:
		return
	var ok := bool(result.get("ok", false))
	_action_label.text = "Action: %s %s — %s" % [
		result.get("character", "?"),
		result.get("action", "?"),
		("ok" if ok else str(result.get("message", "failed"))),
	]


func set_account_logs(entries: Array) -> void:
	if _logs_label == null:
		return
	if entries.is_empty():
		_logs_label.text = "Logs: none"
		return
	var lines: PackedStringArray = []
	var count := mini(entries.size(), 6)
	for i in range(entries.size() - count, entries.size()):
		var entry: Variant = entries[i]
		if entry is Dictionary:
			lines.append("%s: %s" % [entry.get("type", "log"), entry.get("description", "")])
	_logs_label.text = "Logs:\n" + "\n".join(lines)


func set_decisions(decisions: Dictionary) -> void:
	if _decisions_label == null:
		return
	if decisions.is_empty():
		_decisions_label.text = "Decisions: none"
		return
	var lines: PackedStringArray = []
	for character_name in decisions.keys():
		var decision: Variant = decisions[character_name]
		if decision is Dictionary:
			lines.append("%s -> %s (%s)" % [
				character_name,
				decision.get("action", "?"),
				decision.get("reason", ""),
			])
	_decisions_label.text = "Decisions:\n" + "\n".join(lines)


func set_market_signals(signals: Array) -> void:
	if _market_label == null:
		return
	if signals.is_empty():
		_market_label.text = "Market: none"
		return
	var lines: PackedStringArray = []
	for signal_data in signals:
		if signal_data is Dictionary:
			lines.append("%s spread=%s score=%.2f" % [
				signal_data.get("code", "?"),
				signal_data.get("spread", "?"),
				float(signal_data.get("score", 0.0)),
			])
	_market_label.text = "Market:\n" + "\n".join(lines)


func set_characters_from_snapshot(characters: Array) -> void:
	_characters_cooling.clear()
	var selected_hud := {}
	for character in characters:
		if character is Dictionary:
			var name := str(character.get("name", ""))
			_characters_cooling[name] = float(character.get("cooldown", 0))
			if name == _selected_character:
				selected_hud = character
	_update_character_hud(selected_hud)
	_update_action_buttons()


func _update_character_hud(character: Dictionary) -> void:
	if _hud_label == null:
		return
	if character.is_empty():
		_hud_label.text = "HUD: select a character"
		return
	var inv: Variant = character.get("inventory", {})
	var used := 0
	var inv_max := 0
	if inv is Dictionary:
		used = int(inv.get("used", 0))
		inv_max = int(inv.get("max", 0))
	_hud_label.text = "HUD: %s | HP %s/%s | gold %s | inv %s/%s | CD %.0fs" % [
		character.get("name", "?"),
		character.get("hp", "?"),
		character.get("max_hp", "?"),
		character.get("gold", 0),
		used,
		inv_max,
		float(character.get("cooldown", 0)),
	]


func get_host_url() -> String:
	return _host_edit.text.strip_edges() if _host_edit else "ws://127.0.0.1:8787"


func set_host_url(url: String) -> void:
	if _host_edit:
		_host_edit.text = url


func fixtures_only() -> bool:
	return _fixtures_only.button_pressed if _fixtures_only else false


func _refresh_character_options(chars: Array, selected: String) -> void:
	if _character_option == null:
		return
	_character_option.clear()
	var index := 0
	var selected_index := 0
	for character in chars:
		if character is Dictionary:
			var name := str(character.get("name", ""))
			_character_option.add_item(name)
			if name == selected:
				selected_index = index
			index += 1
	if _character_option.item_count > 0:
		_character_option.select(selected_index)
		_selected_character = _character_option.get_item_text(selected_index)


func _update_action_buttons() -> void:
	var cooling := float(_characters_cooling.get(_selected_character, 0.0)) > 0.0
	var content_type := str(_selected_tile.get("content_type", ""))
	if _move_btn:
		_move_btn.disabled = cooling or _selected_tile.is_empty() or _selected_character.is_empty()
	if _fight_btn:
		_fight_btn.disabled = cooling or content_type != "monster" or _selected_character.is_empty()
	if _gather_btn:
		_gather_btn.disabled = cooling or content_type != "resource" or _selected_character.is_empty()
	if _rest_btn:
		_rest_btn.disabled = cooling or _selected_character.is_empty()
	if _bank_deposit_btn:
		_bank_deposit_btn.disabled = cooling or content_type != "bank" or _selected_character.is_empty()
	if _bank_withdraw_btn:
		_bank_withdraw_btn.disabled = cooling or content_type != "bank" or _selected_character.is_empty()
	if _ge_scan_btn:
		_ge_scan_btn.disabled = cooling or content_type != "grand_exchange" or _selected_character.is_empty()


func _emit_action(action_name: String, payload: Dictionary = {}) -> void:
	if _selected_character.is_empty():
		return
	action_requested.emit(action_name, payload)


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = 12.0
	panel.offset_top = 12.0
	panel.offset_right = 460.0
	panel.offset_bottom = 720.0
	add_child(panel)

	var margin := MarginContainer.new()
	for key in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(key, 10)
	panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	var title := Label.new()
	title.text = "Artifacts 3D Visualizer"
	title.add_theme_font_size_override("font_size", 18)
	column.add_child(title)

	_mode_label = Label.new()
	_mode_label.text = "Mode: starting"
	_mode_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_mode_label)

	_status_label = Label.new()
	_status_label.text = "Status: starting"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status_label)

	_session_label = Label.new()
	_session_label.text = "Session: unauthenticated"
	_session_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_session_label)

	_host_edit = LineEdit.new()
	_host_edit.placeholder_text = "ws://127.0.0.1:8787"
	_host_edit.text = "ws://127.0.0.1:8787"
	column.add_child(_host_edit)

	var conn_row := HBoxContainer.new()
	column.add_child(conn_row)
	var connect_btn := Button.new()
	connect_btn.text = "Connect"
	connect_btn.pressed.connect(func() -> void: connect_requested.emit(_host_edit.text.strip_edges()))
	conn_row.add_child(connect_btn)
	var disconnect_btn := Button.new()
	disconnect_btn.text = "Disconnect"
	disconnect_btn.pressed.connect(func() -> void: disconnect_requested.emit())
	conn_row.add_child(disconnect_btn)

	_fixtures_only = CheckButton.new()
	_fixtures_only.text = "Fixtures only (no hub)"
	_fixtures_only.toggled.connect(func(enabled: bool) -> void: fixtures_only_toggled.emit(enabled))
	column.add_child(_fixtures_only)

	_token_edit = LineEdit.new()
	_token_edit.placeholder_text = "Artifacts token"
	_token_edit.secret = true
	column.add_child(_token_edit)

	var auth_row := HBoxContainer.new()
	column.add_child(auth_row)
	var auth_btn := Button.new()
	auth_btn.text = "Auth"
	auth_btn.pressed.connect(func() -> void: auth_requested.emit(_token_edit.text.strip_edges()))
	auth_row.add_child(auth_btn)
	var logout_btn := Button.new()
	logout_btn.text = "Logout"
	logout_btn.pressed.connect(func() -> void: logout_requested.emit())
	auth_row.add_child(logout_btn)

	_character_option = OptionButton.new()
	_character_option.item_selected.connect(func(idx: int) -> void:
		_selected_character = _character_option.get_item_text(idx)
		character_selected.emit(_selected_character)
		_update_action_buttons()
	)
	column.add_child(_character_option)

	_hud_label = Label.new()
	_hud_label.text = "HUD: select a character"
	_hud_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_hud_label)

	_summary_label = Label.new()
	_summary_label.text = "Maps: 0 | Characters: 0"
	column.add_child(_summary_label)

	_selection_label = Label.new()
	_selection_label.text = "Selected: none"
	_selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_selection_label)

	var action_row := HBoxContainer.new()
	column.add_child(action_row)
	_move_btn = Button.new()
	_move_btn.text = "Move"
	_move_btn.pressed.connect(func() -> void:
		_emit_action("move", {
			"x": int(_selected_tile.get("x", 0)),
			"y": int(_selected_tile.get("y", 0)),
			"layer": str(_selected_tile.get("layer", "overworld")),
		})
	)
	action_row.add_child(_move_btn)
	_fight_btn = Button.new()
	_fight_btn.text = "Fight"
	_fight_btn.pressed.connect(func() -> void: _emit_action("fight", {}))
	action_row.add_child(_fight_btn)
	_gather_btn = Button.new()
	_gather_btn.text = "Gather"
	_gather_btn.pressed.connect(func() -> void: _emit_action("gather", {}))
	action_row.add_child(_gather_btn)
	_rest_btn = Button.new()
	_rest_btn.text = "Rest"
	_rest_btn.pressed.connect(func() -> void: _emit_action("rest", {}))
	action_row.add_child(_rest_btn)

	var bank_row := HBoxContainer.new()
	column.add_child(bank_row)
	_bank_deposit_btn = Button.new()
	_bank_deposit_btn.text = "Bank deposit"
	_bank_deposit_btn.pressed.connect(func() -> void: _emit_action("bank-deposit-item", {"items": []}))
	bank_row.add_child(_bank_deposit_btn)
	_bank_withdraw_btn = Button.new()
	_bank_withdraw_btn.text = "Bank withdraw"
	_bank_withdraw_btn.pressed.connect(func() -> void: _emit_action("bank-withdraw-item", {"items": []}))
	bank_row.add_child(_bank_withdraw_btn)
	_ge_scan_btn = Button.new()
	_ge_scan_btn.text = "GE scan"
	_ge_scan_btn.pressed.connect(func() -> void: _emit_action("grand-exchange-orders", {}))
	bank_row.add_child(_ge_scan_btn)

	_action_label = Label.new()
	_action_label.text = "Action: none"
	_action_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_action_label)

	_routes_toggle = CheckButton.new()
	_routes_toggle.text = "Show routes"
	_routes_toggle.button_pressed = true
	_routes_toggle.toggled.connect(func(enabled: bool) -> void: overlay_changed.emit("routes", enabled))
	column.add_child(_routes_toggle)

	_market_toggle = CheckButton.new()
	_market_toggle.text = "Show market signals"
	_market_toggle.button_pressed = true
	_market_toggle.toggled.connect(func(enabled: bool) -> void: overlay_changed.emit("market", enabled))
	column.add_child(_market_toggle)

	_labels_toggle = CheckButton.new()
	_labels_toggle.text = "Show tile labels"
	_labels_toggle.button_pressed = false
	_labels_toggle.toggled.connect(func(enabled: bool) -> void: overlay_changed.emit("labels", enabled))
	column.add_child(_labels_toggle)

	_decisions_label = Label.new()
	_decisions_label.text = "Decisions: none"
	_decisions_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_decisions_label)

	_market_label = Label.new()
	_market_label.text = "Market: none"
	_market_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_market_label)

	_logs_label = Label.new()
	_logs_label.text = "Logs: none"
	_logs_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_logs_label)

	var help := Label.new()
	help.text = "Move: WASD | Orbit: middle-drag | Zoom: wheel | Select: left-click | Rest: R | Follow: F"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)

	_update_action_buttons()
