extends Node
class_name VisualState

signal world_snapshot_updated
signal bot_decision_received(decision: Dictionary)
signal market_signal_received(signal_data: Dictionary)
signal selection_changed(tile: Dictionary)

var maps: Array[Dictionary] = []
var characters: Array[Dictionary] = []
var routes: Array[Dictionary] = []
var events: Array[Dictionary] = []
var raids: Array[Dictionary] = []
var market_signals: Array[Dictionary] = []
var latest_decisions: Dictionary = {}
var selected_tile: Dictionary = {}


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
		_:
			push_warning("Unknown visualizer protocol message: %s" % message_type)


func select_tile(tile: Dictionary) -> void:
	selected_tile = tile
	selection_changed.emit(selected_tile)


func find_tile(layer: String, x: int, y: int) -> Dictionary:
	for tile in maps:
		if str(tile.get("layer", "")) == layer and int(tile.get("x", 0)) == x and int(tile.get("y", 0)) == y:
			return tile
	return {}


func _apply_world_snapshot(data: Dictionary) -> void:
	maps = _as_dictionary_array(data.get("maps", []))
	characters = _as_dictionary_array(data.get("characters", []))
	routes = _as_dictionary_array(data.get("routes", []))
	events = _as_dictionary_array(data.get("events", []))
	raids = _as_dictionary_array(data.get("raids", []))
	world_snapshot_updated.emit()


func _apply_bot_decision(data: Dictionary) -> void:
	var character_name := str(data.get("character", "unknown"))
	latest_decisions[character_name] = data
	bot_decision_received.emit(data)


func _apply_market_signal(data: Dictionary) -> void:
	market_signals.append(data)
	market_signal_received.emit(data)


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
