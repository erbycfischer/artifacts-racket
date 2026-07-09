extends Node3D
class_name MapRenderer

const ArtifactsAssets = preload("res://scripts/artifacts_assets.gd")

signal tile_selected(tile: Dictionary)
signal tile_hovered(tile: Dictionary)

@export var tile_size := 2.0
@export var show_labels := false
@export var show_grid_lines := true
@export var ground_thickness := 0.06

var _selected_key := ""
var _hover_key := ""
var _tile_nodes: Dictionary = {}
var _grid_mat: StandardMaterial3D
var _select_mat: StandardMaterial3D
var _hover_mat: StandardMaterial3D
var _edge_mat: StandardMaterial3D


func _ready() -> void:
	_grid_mat = StandardMaterial3D.new()
	_grid_mat.albedo_color = Color(0.08, 0.1, 0.07, 0.7)
	_grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_edge_mat = StandardMaterial3D.new()
	_edge_mat.albedo_color = Color(0.05, 0.06, 0.04, 0.85)
	_edge_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_select_mat = StandardMaterial3D.new()
	_select_mat.albedo_color = Color(1.0, 0.86, 0.25, 0.95)
	_select_mat.emission_enabled = true
	_select_mat.emission = Color(0.95, 0.75, 0.15)
	_select_mat.emission_energy_multiplier = 1.4
	_select_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_hover_mat = StandardMaterial3D.new()
	_hover_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.28)
	_hover_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func render_world(maps: Array) -> void:
	_clear_children()
	_tile_nodes.clear()
	for tile in maps:
		if tile is Dictionary:
			_add_tile(tile)


func grid_to_world(tile: Dictionary) -> Vector3:
	var x := float(tile.get("x", 0))
	var y := float(tile.get("y", 0))
	var layer := str(tile.get("layer", "overworld"))
	return Vector3(x * tile_size, _layer_height(layer), y * tile_size)


func set_selected_tile(tile: Dictionary) -> void:
	_selected_key = _tile_key(tile)
	_refresh_highlights()


func _add_tile(tile: Dictionary) -> void:
	var key := _tile_key(tile)
	var tile_body := StaticBody3D.new()
	tile_body.name = "Tile_%s" % key
	tile_body.position = grid_to_world(tile)
	tile_body.input_ray_pickable = true
	tile_body.input_event.connect(_on_tile_input.bind(tile))
	tile_body.mouse_entered.connect(func() -> void:
		_hover_key = key
		_refresh_highlights()
		tile_hovered.emit(tile)
	)
	tile_body.mouse_exited.connect(func() -> void:
		if _hover_key == key:
			_hover_key = ""
			_refresh_highlights()
	)
	add_child(tile_body)
	_tile_nodes[key] = tile_body

	# Flat board cell: thin slab with official map skin on top face.
	var ground := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(tile_size * 0.995, ground_thickness, tile_size * 0.995)
	ground.mesh = box
	ground.position.y = ground_thickness * 0.5
	ground.material_override = ArtifactsAssets.tile_material(str(tile.get("skin", "forest_1")))
	tile_body.add_child(ground)

	if show_grid_lines:
		_add_cell_border(tile_body)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(tile_size * 0.995, maxf(ground_thickness, 0.15), tile_size * 0.995)
	shape.shape = box_shape
	shape.position.y = maxf(ground_thickness, 0.15) * 0.5
	tile_body.add_child(shape)

	var content_type := _content_type(tile)
	var content_code := _content_code(tile)
	if content_type != "terrain" and not content_type.is_empty():
		_add_content_prop(tile_body, content_type, content_code)

	var select_ring := MeshInstance3D.new()
	select_ring.name = "SelectRing"
	var torus := TorusMesh.new()
	torus.inner_radius = tile_size * 0.40
	torus.outer_radius = tile_size * 0.48
	select_ring.mesh = torus
	select_ring.rotation_degrees = Vector3(90, 0, 0)
	select_ring.position.y = ground_thickness + 0.04
	select_ring.material_override = _select_mat
	select_ring.visible = false
	tile_body.add_child(select_ring)

	var hover_plane := MeshInstance3D.new()
	hover_plane.name = "HoverPlane"
	var plane := BoxMesh.new()
	plane.size = Vector3(tile_size * 0.96, 0.015, tile_size * 0.96)
	hover_plane.mesh = plane
	hover_plane.position.y = ground_thickness + 0.025
	hover_plane.material_override = _hover_mat
	hover_plane.visible = false
	tile_body.add_child(hover_plane)

	if show_labels and not content_code.is_empty():
		_add_label(tile_body, content_code, ground_thickness)


func _add_cell_border(parent: Node3D) -> void:
	# Four thin edge bars so the board reads as a grid, not floating cubes.
	var half := tile_size * 0.5
	var t := 0.04
	var h := 0.02
	var edges := [
		[Vector3(0, h, -half + t * 0.5), Vector3(tile_size, h, t)],
		[Vector3(0, h, half - t * 0.5), Vector3(tile_size, h, t)],
		[Vector3(-half + t * 0.5, h, 0), Vector3(t, h, tile_size)],
		[Vector3(half - t * 0.5, h, 0), Vector3(t, h, tile_size)],
	]
	for edge in edges:
		var bar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = edge[1]
		bar.mesh = box
		bar.position = edge[0]
		bar.material_override = _edge_mat
		parent.add_child(bar)


func _add_content_prop(parent: Node3D, content_type: String, content_code: String) -> void:
	var tex: Texture2D = ArtifactsAssets.content_texture(content_type, content_code)
	var mat: StandardMaterial3D = ArtifactsAssets.billboard_material(tex, _content_fallback(content_type))
	var sprite := MeshInstance3D.new()
	var quad := QuadMesh.new()
	var size := _content_sprite_size(content_type)
	quad.size = size
	sprite.mesh = quad
	sprite.material_override = mat
	sprite.position = Vector3(0.0, ground_thickness + size.y * 0.5 + 0.02, 0.0)
	parent.add_child(sprite)


func _content_sprite_size(content_type: String) -> Vector2:
	match content_type:
		"monster", "raid":
			return Vector2(1.15, 1.15)
		"resource":
			return Vector2(1.05, 1.2)
		"bank", "grand_exchange", "workshop":
			return Vector2(1.2, 1.2)
		_:
			return Vector2(1.0, 1.0)


func _content_fallback(content_type: String) -> Color:
	match content_type:
		"bank":
			return Color(0.3, 0.45, 0.85)
		"grand_exchange":
			return Color(0.9, 0.75, 0.2)
		"monster", "raid":
			return Color(0.75, 0.25, 0.2)
		"resource":
			return Color(0.25, 0.55, 0.3)
		"npc", "tasks_master":
			return Color(0.55, 0.45, 0.75)
		"event":
			return Color(0.95, 0.5, 0.2)
		_:
			return Color(0.5, 0.5, 0.5)


func _add_label(parent: Node3D, text: String, height: float) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 18
	label.outline_size = 6
	label.position = Vector3(0.0, height + 1.35, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	parent.add_child(label)


func _refresh_highlights() -> void:
	for key in _tile_nodes.keys():
		var node: Node = _tile_nodes[key]
		var select_ring := node.get_node_or_null("SelectRing") as MeshInstance3D
		var hover_plane := node.get_node_or_null("HoverPlane") as MeshInstance3D
		if select_ring:
			select_ring.visible = (key == _selected_key)
		if hover_plane:
			hover_plane.visible = (key == _hover_key and key != _selected_key)


func _tile_key(tile: Dictionary) -> String:
	return "%s_%s_%s" % [tile.get("layer", "overworld"), tile.get("x", 0), tile.get("y", 0)]


func _content_type(tile: Dictionary) -> String:
	var direct := str(tile.get("content_type", ""))
	if not direct.is_empty():
		return direct
	var interactions: Variant = tile.get("interactions", {})
	if interactions is Dictionary:
		var content: Variant = interactions.get("content", {})
		if content is Dictionary:
			return str(content.get("type", "terrain"))
	return "terrain"


func _content_code(tile: Dictionary) -> String:
	var direct := str(tile.get("content_code", ""))
	if not direct.is_empty():
		return direct
	var interactions: Variant = tile.get("interactions", {})
	if interactions is Dictionary:
		var content: Variant = interactions.get("content", {})
		if content is Dictionary:
			return str(content.get("code", ""))
	return ""


func _layer_height(layer: String) -> float:
	match layer:
		"underground":
			return -2.2
		"interior":
			return 2.2
		"sky":
			return 4.0
		_:
			return 0.0


func _on_tile_input(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int, tile: Dictionary) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		set_selected_tile(tile)
		tile_selected.emit(tile)


func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
