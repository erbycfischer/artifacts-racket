extends Node3D
class_name MarkerRenderer

@export var tile_size := 2.0
@export var show_routes := true
@export var show_market_signals := true

var _character_material: StandardMaterial3D
var _route_material: StandardMaterial3D
var _event_material: StandardMaterial3D
var _raid_material: StandardMaterial3D
var _decision_material: StandardMaterial3D
var _market_material: StandardMaterial3D
var _cooldown_material: StandardMaterial3D


func _ready() -> void:
	_character_material = _make_material(Color(0.15, 0.85, 0.95))
	_route_material = _make_material(Color(0.95, 0.95, 0.35), 0.55)
	_event_material = _make_material(Color(0.95, 0.45, 0.15))
	_raid_material = _make_material(Color(0.7, 0.2, 0.95))
	_decision_material = _make_material(Color(1.0, 0.35, 0.75), 0.7)
	_market_material = _make_material(Color(0.95, 0.8, 0.2), 0.65)
	_cooldown_material = _make_material(Color(0.35, 0.55, 1.0), 0.45)


func render_state(state: Node) -> void:
	_clear_children()
	var characters: Array = state.get("characters")
	var decisions: Dictionary = state.get("latest_decisions")
	var routes: Array = state.get("routes")
	var events: Array = state.get("events")
	var raids: Array = state.get("raids")
	var market_signals: Array = state.get("market_signals")
	_render_characters(characters, decisions)
	if show_routes:
		_render_routes(routes)
	_render_points(events, "Event", _event_material, 0.55)
	_render_points(raids, "Raid", _raid_material, 0.7)
	if show_market_signals:
		_render_market_signals(market_signals)


func _render_characters(characters: Array, decisions: Dictionary) -> void:
	for character in characters:
		var marker := MeshInstance3D.new()
		marker.name = "Character_%s" % character.get("name", "unknown")
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.25
		capsule.height = 0.9
		marker.mesh = capsule
		marker.material_override = _character_material
		marker.position = _grid_to_world(character) + Vector3(0.0, 0.55, 0.0)
		add_child(marker)

		var label := Label3D.new()
		label.text = str(character.get("name", "char"))
		label.font_size = 28
		label.position = Vector3(0.0, 0.85, 0.0)
		marker.add_child(label)

		var cooldown := float(character.get("cooldown", 0))
		if cooldown > 0.0 or bool(character.get("on_cooldown", false)):
			_add_cooldown_ring(marker, cooldown)

		var decision: Variant = decisions.get(str(character.get("name", "")), {})
		if decision is Dictionary and not decision.is_empty():
			_add_decision_pulse(marker, decision)



func _add_cooldown_ring(parent: Node3D, cooldown: float) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	var scale := clampf(0.35 + minf(cooldown, 20.0) * 0.02, 0.35, 0.75)
	torus.inner_radius = scale
	torus.outer_radius = scale + 0.12
	ring.mesh = torus
	ring.material_override = _cooldown_material
	ring.position = Vector3(0.0, -0.35, 0.0)
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	parent.add_child(ring)

	var label := Label3D.new()
	label.text = ("CD %.0fs" % cooldown) if cooldown > 0.0 else "CD"
	label.font_size = 18
	label.modulate = Color(0.55, 0.75, 1.0)
	label.position = Vector3(0.0, -0.05, 0.0)
	parent.add_child(label)


func _add_decision_pulse(parent: Node3D, decision: Dictionary) -> void:
	var pulse := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.35
	torus.outer_radius = 0.5
	pulse.mesh = torus
	pulse.material_override = _decision_material
	pulse.position = Vector3(0.0, -0.2, 0.0)
	parent.add_child(pulse)

	var label := Label3D.new()
	label.text = "%s (%s)" % [decision.get("action", "?"), decision.get("reason", "")]
	label.font_size = 20
	label.position = Vector3(0.0, 1.15, 0.0)
	parent.add_child(label)


func _render_routes(routes: Array) -> void:
	for route in routes:
		var points: Variant = route.get("points", [])
		if not (points is Array) or points.size() < 2:
			continue
		for i in range(points.size() - 1):
			var a: Variant = points[i]
			var b: Variant = points[i + 1]
			if not (a is Dictionary and b is Dictionary):
				continue
			_add_route_segment(a, b)


func _add_route_segment(a: Dictionary, b: Dictionary) -> void:
	var start := _grid_to_world(a) + Vector3(0.0, 0.2, 0.0)
	var end := _grid_to_world(b) + Vector3(0.0, 0.2, 0.0)
	var mid := (start + end) * 0.5
	var length := start.distance_to(end)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.08, max(length, 0.1))
	mesh.mesh = box
	mesh.material_override = _route_material
	mesh.position = mid
	mesh.look_at_from_position(mid, end, Vector3.UP)
	add_child(mesh)


func _render_points(items: Array, prefix: String, material: StandardMaterial3D, height: float) -> void:
	for item in items:
		var marker := MeshInstance3D.new()
		marker.name = "%s_%s" % [prefix, item.get("code", item.get("name", "item"))]
		var sphere := SphereMesh.new()
		sphere.radius = 0.28
		sphere.height = 0.56
		marker.mesh = sphere
		marker.material_override = material
		marker.position = _grid_to_world(item) + Vector3(0.0, height, 0.0)
		add_child(marker)


func _render_market_signals(signals: Array) -> void:
	for signal_data in signals:
		var marker := MeshInstance3D.new()
		marker.name = "Market_%s" % signal_data.get("code", "signal")
		var prism := PrismMesh.new()
		prism.size = Vector3(0.5, 0.7, 0.5)
		marker.mesh = prism
		marker.material_override = _market_material
		var tile := {
			"x": signal_data.get("x", 0),
			"y": signal_data.get("y", 0),
			"layer": signal_data.get("layer", "overworld"),
		}
		marker.position = _grid_to_world(tile) + Vector3(0.0, 1.0, 0.0)
		add_child(marker)

		var label := Label3D.new()
		label.text = "%s %.2f" % [signal_data.get("code", "?"), float(signal_data.get("score", 0.0))]
		label.font_size = 22
		label.position = Vector3(0.0, 0.7, 0.0)
		marker.add_child(label)


func _grid_to_world(tile: Dictionary) -> Vector3:
	var x := float(tile.get("x", 0))
	var y := float(tile.get("y", 0))
	var layer := str(tile.get("layer", "overworld"))
	var elevation := 0.0
	match layer:
		"underground":
			elevation = -0.35
		"sky":
			elevation = 0.55
	return Vector3(x * tile_size, elevation, y * tile_size)


func _make_material(color: Color, alpha: float = 1.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	if alpha < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
