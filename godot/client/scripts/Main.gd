extends Node3D

const FIXTURE_PATHS: Array[String] = [
	"res://fixtures/world_snapshot.json",
	"res://fixtures/bot_decision.json",
	"res://fixtures/market_signal.json",
]

@onready var visual_state: VisualState = $VisualState
@onready var state_client: StateClient = $StateClient
@onready var map_renderer: MapRenderer = $WorldRoot/MapRenderer
@onready var marker_renderer: MarkerRenderer = $WorldRoot/MarkerRenderer
@onready var ui_root: VisualizerUI = $UIRoot


func _ready() -> void:
	_connect_signals()
	_load_fixture_messages()
	state_client.connect_to_server()


func _connect_signals() -> void:
	state_client.status_changed.connect(ui_root.set_status)
	state_client.message_received.connect(_on_protocol_message)
	visual_state.world_snapshot_updated.connect(_on_world_snapshot_updated)
	visual_state.bot_decision_received.connect(_on_overlay_state_changed)
	visual_state.market_signal_received.connect(_on_overlay_state_changed)
	visual_state.selection_changed.connect(ui_root.set_selected_tile)
	map_renderer.tile_selected.connect(visual_state.select_tile)
	ui_root.overlay_changed.connect(_on_overlay_changed)


func _load_fixture_messages() -> void:
	for path in FIXTURE_PATHS:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_warning("Missing visualizer fixture: %s" % path)
			continue

		var parsed: Variant = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			visual_state.apply_message(parsed)
		else:
			push_warning("Fixture did not contain a protocol message: %s" % path)

	ui_root.set_status("offline fixtures loaded; waiting for ws://127.0.0.1:8787")


func _on_protocol_message(message: Dictionary) -> void:
	visual_state.apply_message(message)


func _on_world_snapshot_updated() -> void:
	map_renderer.render_world(visual_state.maps)
	marker_renderer.render_state(visual_state)
	ui_root.set_world_summary(visual_state.maps.size(), visual_state.characters.size())


func _on_overlay_state_changed(_payload: Dictionary) -> void:
	marker_renderer.render_state(visual_state)
	ui_root.set_decisions(visual_state.latest_decisions)
	ui_root.set_market_signals(visual_state.market_signals)


func _on_overlay_changed(overlay_name: String, enabled: bool) -> void:
	match overlay_name:
		"routes":
			marker_renderer.show_routes = enabled
		"market":
			marker_renderer.show_market_signals = enabled
		"labels":
			map_renderer.show_labels = enabled
			map_renderer.render_world(visual_state.maps)
		_:
			return
	marker_renderer.render_state(visual_state)
