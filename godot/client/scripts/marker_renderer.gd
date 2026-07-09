extends Node3D
class_name MarkerRenderer

const ArtifactsAssets = preload("res://scripts/artifacts_assets.gd")

@export var tile_size := 2.0
@export var show_routes := true
@export var show_market_signals := true
@export var ground_thickness := 0.08

var _route_material: StandardMaterial3D
var _event_material: StandardMaterial3D
var _raid_material: StandardMaterial3D
var _decision_material: StandardMaterial3D
var _market_material: StandardMaterial3D
var _cooldown_material: StandardMaterial3D
var _mine_tint := Color(0.15, 0.9, 1.0)
var _other_tint := Color(1.0, 0.72, 0.25)


func _ready() -> void:
	_route_material = _make_material(Color(1.0, 0.92, 0.25, 0.85), true)
	_event_material = _make_material(Color(0.95, 0.5, 0.15))
	_raid_material = _make_material(Color(0.75, 0.25, 0.2))
	_decision_material = _make_material(Color(0.2, 0.95, 0.75, 0.9), true)
	_market_material = _make_material(Color(0.95, 0.8, 0.2))
	_cooldown_material = _make_material(Color(0.35, 0.55, 1.0, 0.7), true)


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
	_render_points(events, "Event", _event_material, 0.9)
	_render_points(raids, "Raid", _raid_material, 1.0)
	if show_market_signals:
		_render_market_signals(market_signals)


func _render_characters(characters: Array, decisions: Dictionary) -> void:
	for character in characters:
		if not (character is Dictionary):
			continue
		var root := Node3D.new()
		root.name = "Character_%s" % character.get("name", "unknown")
		root.position = _grid_to_world(character)
		add_child(root)

		var is_other := bool(character.get("other", false))
		var skin := str(character.get("skin", "men1"))
		var tex := ArtifactsAssets.character_texture(skin)
		var mat := ArtifactsAssets.billboard_material(tex, _other_tint if is_other else _mine_tint)

		var sprite := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.95, 1.2)
		sprite.mesh = quad
		sprite.material_override = mat
		sprite.position = Vector3(0.0, ground_thickness + 0.7, 0.0)
		root.add_child(sprite)

		# Ground disc so characters read as standing on a cell.
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.35
		cyl.bottom_radius = 0.35
		cyl.height = 0.04
		disc.mesh = cyl
		disc.position.y = ground_thickness + 0.03
		var disc_mat := StandardMaterial3D.new()
		disc_mat.albedo_color = _other_tint if is_other else _mine_tint
		disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		disc_mat.albedo_color.a = 0.55
		disc.material_override = disc_mat
		root.add_child(disc)

		var label := Label3D.new()
		var name := str(character.get("name", "char"))
		label.text = ("[world] %s" % name) if is_other else name
		label.font_size = 22
		label.outline_size = 8
		label.position = Vector3(0.0, ground_thickness + 1.45, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		root.add_child(label)

		var cooldown := float(character.get("cooldown", 0))
		if cooldown > 0.0 or bool(character.get("on_cooldown", false)):
			_add_cooldown_ring(root, cooldown)

		var decision: Variant = decisions.get(str(character.get("name", "")), {})
		if decision is Dictionary and not decision.is_empty() and not is_other:
			_add_decision_pulse(root, decision)


func _add_cooldown_ring(parent: Node3D, cooldown: float) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	var scale := clampf(0.28 + minf(cooldown, 20.0) * 0.015, 0.28, 0.55)
	torus.inner_radius = scale
	torus.outer_radius = scale + 0.08
	ring.mesh = torus
	ring.material_override = _cooldown_material
	ring.position = Vector3(0.0, ground_thickness + 0.08, 0.0)
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	parent.add_child(ring)


func _add_decision_pulse(parent: Node3D, decision: Dictionary) -> void:
	var pulse := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.4
	torus.outer_radius = 0.5
	pulse.mesh = torus
	pulse.material_override = _decision_material
	pulse.position = Vector3(0.0, ground_thickness + 0.1, 0.0)
	pulse.rotation_degrees = Vector3(90, 0, 0)
	parent.add_child(pulse)

	var label := Label3D.new()
	label.text = str(decision.get("action", "?"))
	label.font_size = 18
	label.outline_size = 6
	label.position = Vector3(0.0, ground_thickness + 1.7, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	parent.add_child(label)


func _render_routes(routes: Array) -> void:
	for route in routes:
		if not (route is Dictionary):
			continue
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
	var start := _grid_to_world(a) + Vector3(0.0, ground_thickness + 0.06, 0.0)
	var end := _grid_to_world(b) + Vector3(0.0, ground_thickness + 0.06, 0.0)
	var mid := (start + end) * 0.5
	var length := start.distance_to(end)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.18, 0.05, max(length, 0.1))
	mesh.mesh = box
	mesh.material_override = _route_material
	mesh.position = mid
	mesh.look_at_from_position(mid, end, Vector3.UP)
	add_child(mesh)


func _render_points(items: Array, prefix: String, material: StandardMaterial3D, height: float) -> void:
	for item in items:
		if not (item is Dictionary):
			continue
		var marker := MeshInstance3D.new()
		marker.name = "%s_%s" % [prefix, item.get("code", item.get("name", "item"))]
		var sphere := SphereMesh.new()
		sphere.radius = 0.22
		sphere.height = 0.44
		marker.mesh = sphere
		marker.material_override = material
		marker.position = _grid_to_world(item) + Vector3(0.0, ground_thickness + height, 0.0)
		add_child(marker)


func _render_market_signals(signals: Array) -> void:
	for signal_data in signals:
		if not (signal_data is Dictionary):
			continue
		var marker := MeshInstance3D.new()
		marker.name = "Market_%s" % signal_data.get("code", "signal")
		var prism := PrismMesh.new()
		prism.size = Vector3(0.4, 0.55, 0.4)
		marker.mesh = prism
		marker.material_override = _market_material
		var tile := {
			"x": signal_data.get("x", 0),
			"y": signal_data.get("y", 0),
			"layer": signal_data.get("layer", "overworld"),
		}
		marker.position = _grid_to_world(tile) + Vector3(0.0, ground_thickness + 1.15, 0.0)
		add_child(marker)


func _grid_to_world(tile: Dictionary) -> Vector3:
	var x := float(tile.get("x", 0))
	var y := float(tile.get("y", 0))
	var layer := str(tile.get("layer", "overworld"))
	var elevation := 0.0
	match layer:
		"underground":
			elevation = -2.2
		"interior":
			elevation = 2.2
		"sky":
			elevation = 4.0
	return Vector3(x * tile_size, elevation, y * tile_size)


func _make_material(color: Color, alpha_ok: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	if alpha_ok and color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
