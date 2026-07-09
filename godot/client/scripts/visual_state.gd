extends Node
class_name VisualState

signal world_snapshot_updated
signal bot_decision_received(decision: Dictionary)
signal market_signal_received(signal_data: Dictionary)
signal selection_changed(tile: Dictionary)
signal session_status_received(status: Dictionary)
signal action_result_received(result: Dictionary)
signal account_logs_received(entries: Array)
signal selected_character_changed(character_name: String)

var maps: Array[Dictionary] = []
var characters: Array[Dictionary] = []
var routes: Array[Dictionary] = []
var events: Array[Dictionary] = []
var raids: Array[Dictionary] = []
var market_signals: Array[Dictionary] = []
var latest_decisions: Dictionary = {}
var selected_tile: Dictionary = {}
var session_status: Dictionary = {}
var last_action_result: Dictionary = {}
var account_logs: Array[Dictionary] = []
var selected_character: String = ""
const MARKET_SIGNAL_LIMIT := 12


func apply_message(message: Dictionary) -> void:
	var message_type := str(message.get("type", ""))
	var data := _as_dictionary(message.get("data", {}))

	match message_type:
		"world.snapshot":
			_apply_world_snapshot(data)
		"bot.decision":
			_apply_bot_decision(data)
		"market.signal":
			_apply_market_signal(data)
		"session.status":
			_apply_session_status(data)
		"action.result":
			_apply_action_result(data)
		"account.logs":
			_apply_account_logs(data)
		_:
			push_warning("Unknown visualizer protocol message: %s" % message_type)


func select_tile(tile: Dictionary) -> void:
	selected_tile = tile
	selection_changed.emit(selected_tile)


func select_character(character_name: String) -> void:
	selected_character = character_name
	selected_character_changed.emit(selected_character)


func find_tile(layer: String, x: int, y: int) -> Dictionary:
	for tile in maps:
		if str(tile.get("layer", "")) == layer and int(tile.get("x", 0)) == x and int(tile.get("y", 0)) == y:
			return tile
	return {}


func find_character(character_name: String) -> Dictionary:
	for character in characters:
		if str(character.get("name", "")) == character_name:
			return character
	return {}


func clear_live_overlays() -> void:
	maps.clear()
	characters.clear()
	routes.clear()
	events.clear()
	raids.clear()
	market_signals.clear()
	latest_decisions.clear()
	world_snapshot_updated.emit()


func _apply_world_snapshot(data: Dictionary) -> void:
	maps = _as_dictionary_array(data.get("maps", []))
	characters = _as_dictionary_array(data.get("characters", []))
	routes = _as_dictionary_array(data.get("routes", []))
	events = _as_dictionary_array(data.get("events", []))
	raids = _as_dictionary_array(data.get("raids", []))
	if selected_character.is_empty() and not characters.is_empty():
		select_character(str(characters[0].get("name", "")))
	world_snapshot_updated.emit()


func _apply_bot_decision(data: Dictionary) -> void:
	var character_name := str(data.get("character", "unknown"))
	latest_decisions[character_name] = data
	bot_decision_received.emit(data)


func _apply_market_signal(data: Dictionary) -> void:
	var code := str(data.get("code", ""))
	if not code.is_empty():
		for i in range(market_signals.size() - 1, -1, -1):
			if str(market_signals[i].get("code", "")) == code:
				market_signals.remove_at(i)
	market_signals.append(data)
	while market_signals.size() > MARKET_SIGNAL_LIMIT:
		market_signals.remove_at(0)
	market_signal_received.emit(data)


func _apply_session_status(data: Dictionary) -> void:
	session_status = data
	var selected := str(data.get("selected", ""))
	if not selected.is_empty() and selected != selected_character:
		select_character(selected)
	session_status_received.emit(data)


func _apply_action_result(data: Dictionary) -> void:
	last_action_result = data
	action_result_received.emit(data)


func _apply_account_logs(data: Dictionary) -> void:
	account_logs = _as_dictionary_array(data.get("entries", []))
	account_logs_received.emit(account_logs)


func _as_dictionary(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


func _as_dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				result.append(item)
	return result
