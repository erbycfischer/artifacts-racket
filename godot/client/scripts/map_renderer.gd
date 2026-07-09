extends Node3D
class_name MapRenderer

const ArtifactsAssets = preload("res://scripts/artifacts_assets.gd")

signal tile_selected(tile: Dictionary)
signal tile_hovered(tile: Dictionary)

@export var tile_size := 2.0
@export var show_labels := false
@export var show_grid_lines := false
@export var ground_thickness := 0.12
@export var seam_overlap := 0.08

var _selected_key := ""
var _hover_key := ""
var _tile_nodes: Dictionary = {}
var _tile_data: Dictionary = {}
var _select_mat: StandardMaterial3D
var _hover_mat: StandardMaterial3D
var _shadow_mat: StandardMaterial3D
var _prop_mats: Dictionary = {}
var _terrain_root: Node3D
var _props_root: Node3D
var _pick_root: Node3D


func _ready() -> void:
	_select_mat = StandardMaterial3D.new()
	_select_mat.albedo_color = Color(1.0, 0.88, 0.28, 0.95)
	_select_mat.emission_enabled = true
	_select_mat.emission = Color(0.95, 0.78, 0.2)
	_select_mat.emission_energy_multiplier = 1.6
	_select_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_hover_mat = StandardMaterial3D.new()
	_hover_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.22)
	_hover_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_shadow_mat = StandardMaterial3D.new()
	_shadow_mat.albedo_color = Color(0.02, 0.03, 0.02, 0.35)
	_shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func render_world(maps: Array) -> void:
	_clear_children()
	_tile_nodes.clear()
	_tile_data.clear()
	_prop_mats.clear()

	_terrain_root = Node3D.new()
	_terrain_root.name = "Terrain"
	add_child(_terrain_root)
	_props_root = Node3D.new()
	_props_root.name = "Props"
	add_child(_props_root)
	_pick_root = Node3D.new()
	_pick_root.name = "Pickables"
	add_child(_pick_root)

	var by_layer: Dictionary = {}
	for tile in maps:
		if not (tile is Dictionary):
			continue
		var layer := str(tile.get("layer", "overworld"))
		if not by_layer.has(layer):
			by_layer[layer] = []
		(by_layer[layer] as Array).append(tile)
		_tile_data[_tile_key(tile)] = tile

	for layer in by_layer.keys():
		_build_seamless_terrain(layer, by_layer[layer])

	for tile in maps:
		if tile is Dictionary:
			_add_tile_pickable(tile)
			var content_type := _content_type(tile)
			if content_type != "terrain" and not content_type.is_empty():
				_add_content_prop(tile, content_type, _content_code(tile))


func grid_to_world(tile: Dictionary) -> Vector3:
	var x := float(tile.get("x", 0))
	var y := float(tile.get("y", 0))
	var layer := str(tile.get("layer", "overworld"))
	var skin := str(tile.get("skin", "forest_1"))
	return Vector3(x * tile_size, _layer_height(layer) + _skin_height(skin), y * tile_size)


func set_selected_tile(tile: Dictionary) -> void:
	_selected_key = _tile_key(tile)
	_refresh_highlights()


func _build_seamless_terrain(layer: String, tiles: Array) -> void:
	if tiles.is_empty():
		return

	# Group by skin so same-biome patches share one continuous mesh look.
	var by_skin: Dictionary = {}
	for tile in tiles:
		var skin := str(tile.get("skin", "forest_1"))
		if not by_skin.has(skin):
			by_skin[skin] = []
		(by_skin[skin] as Array).append(tile)

	var layer_y := _layer_height(layer)
	for skin in by_skin.keys():
		var skin_tiles: Array = by_skin[skin]
		var mat := ArtifactsAssets.tile_material(skin)
		mat.roughness = 0.92
		# Soften nearest-neighbor tile look slightly for continuous ground.
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

		for tile in skin_tiles:
			var cell := _make_ground_cell(tile, layer_y, mat)
			_terrain_root.add_child(cell)

		# Soft skirt under each skin cluster to hide cube edges.
		_add_biome_skirts(skin_tiles, layer_y, skin)


func _make_ground_cell(tile: Dictionary, layer_y: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var skin := str(tile.get("skin", "forest_1"))
	var h := ground_thickness + _skin_height(skin)
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	# Overlap neighbors so seams disappear.
	var span := tile_size + seam_overlap
	box.size = Vector3(span, h, span)
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	var pos := grid_to_world(tile)
	# Flatten Y to layer base + half thickness so overlapping cells align.
	mesh_inst.position = Vector3(pos.x, layer_y + h * 0.5, pos.z)
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Micro height noise via slight Y offset from hash — keeps surface alive.
	var jitter := _hash01(int(tile.get("x", 0)), int(tile.get("y", 0))) * 0.04
	mesh_inst.position.y += jitter
	return mesh_inst


func _add_biome_skirts(tiles: Array, layer_y: float, skin: String) -> void:
	var color := ArtifactsAssets.skin_base_color(skin)
	color = color.darkened(0.35)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	for tile in tiles:
		var skirt := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(tile_size + seam_overlap * 1.5, 0.35, tile_size + seam_overlap * 1.5)
		skirt.mesh = box
		skirt.material_override = mat
		var pos := grid_to_world(tile)
		skirt.position = Vector3(pos.x, layer_y - 0.12, pos.z)
		skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_terrain_root.add_child(skirt)

		# Sparse ground clutter for volumetric feel.
		if _content_type(tile) == "terrain" and _hash01(int(tile.get("x", 0)) + 3, int(tile.get("y", 0))) > 0.55:
			_add_ground_clutter(tile, skin)


func _add_ground_clutter(tile: Dictionary, skin: String) -> void:
	var root := Node3D.new()
	root.position = grid_to_world(tile) + Vector3(0.0, ground_thickness + 0.02, 0.0)
	_props_root.add_child(root)
	var s := skin.to_lower()
	if "water" in s or "lake" in s:
		return
	if "mountain" in s or "mine" in s:
		_add_rock_cluster(root, 0.7)
	else:
		# Small grass tufts / pebbles
		var count := 2 + int(_hash01(int(tile.get("x", 0)), int(tile.get("y", 0)) + 7) * 3.0)
		for i in range(count):
			var tuft := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.06 + _hash01(i, int(tile.get("x", 0))) * 0.05
			cone.height = 0.12 + _hash01(i + 1, int(tile.get("y", 0))) * 0.1
			tuft.mesh = cone
			var mat := _cached_prop_mat("grass", Color(0.22, 0.48, 0.2))
			tuft.material_override = mat
			var ox := (_hash01(i, 11) - 0.5) * tile_size * 0.7
			var oz := (_hash01(i, 17) - 0.5) * tile_size * 0.7
			tuft.position = Vector3(ox, cone.height * 0.5, oz)
			root.add_child(tuft)


func _add_tile_pickable(tile: Dictionary) -> void:
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
	_pick_root.add_child(tile_body)
	_tile_nodes[key] = tile_body

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(tile_size * 0.98, maxf(ground_thickness, 0.2), tile_size * 0.98)
	shape.shape = box_shape
	shape.position.y = maxf(ground_thickness, 0.2) * 0.5
	tile_body.add_child(shape)

	var select_ring := MeshInstance3D.new()
	select_ring.name = "SelectRing"
	var torus := TorusMesh.new()
	torus.inner_radius = tile_size * 0.38
	torus.outer_radius = tile_size * 0.46
	torus.rings = 12
	torus.ring_segments = 24
	select_ring.mesh = torus
	select_ring.rotation_degrees = Vector3(90, 0, 0)
	select_ring.position.y = ground_thickness + 0.06
	select_ring.material_override = _select_mat
	select_ring.visible = false
	tile_body.add_child(select_ring)

	var hover_plane := MeshInstance3D.new()
	hover_plane.name = "HoverPlane"
	var plane := BoxMesh.new()
	plane.size = Vector3(tile_size * 0.92, 0.02, tile_size * 0.92)
	hover_plane.mesh = plane
	hover_plane.position.y = ground_thickness + 0.04
	hover_plane.material_override = _hover_mat
	hover_plane.visible = false
	tile_body.add_child(hover_plane)

	if show_labels:
		var content_code := _content_code(tile)
		if not content_code.is_empty():
			_add_label(tile_body, content_code, ground_thickness)


func _add_content_prop(tile: Dictionary, content_type: String, content_code: String) -> void:
	var root := Node3D.new()
	root.name = "Prop_%s_%s" % [content_type, content_code]
	root.position = grid_to_world(tile) + Vector3(0.0, ground_thickness, 0.0)
	_props_root.add_child(root)

	# Soft contact shadow
	var shadow := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.55
	disc.bottom_radius = 0.55
	disc.height = 0.03
	shadow.mesh = disc
	shadow.position.y = 0.02
	shadow.material_override = _shadow_mat
	root.add_child(shadow)

	match content_type:
		"resource":
			_add_tree_prop(root, content_code)
		"monster", "raid":
			_add_creature_prop(root, content_type, content_code)
		"bank", "grand_exchange", "workshop":
			_add_building_prop(root, content_type)
		"npc", "tasks_master":
			_add_npc_prop(root)
		"event":
			_add_event_prop(root)
		_:
			_add_generic_prop(root, content_type)

	# Small official art accent (billboard) so content stays recognizable.
	var tex: Texture2D = ArtifactsAssets.content_texture(content_type, content_code)
	if tex != null:
		var accent := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.55, 0.55)
		accent.mesh = quad
		accent.material_override = ArtifactsAssets.billboard_material(tex, _content_fallback(content_type))
		accent.position = Vector3(0.55, 1.15, 0.55)
		root.add_child(accent)


func _add_tree_prop(root: Node3D, _code: String) -> void:
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.1
	cyl.bottom_radius = 0.14
	cyl.height = 0.85
	trunk.mesh = cyl
	trunk.position.y = 0.45
	trunk.material_override = _cached_prop_mat("trunk", Color(0.35, 0.22, 0.12))
	root.add_child(trunk)

	var foliage := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.02
	cone.bottom_radius = 0.55
	cone.height = 0.95
	foliage.mesh = cone
	foliage.position.y = 1.15
	foliage.material_override = _cached_prop_mat("leaf", Color(0.2, 0.5, 0.22))
	root.add_child(foliage)

	var canopy := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.42
	sphere.height = 0.7
	canopy.mesh = sphere
	canopy.position.y = 1.45
	canopy.material_override = _cached_prop_mat("canopy", Color(0.18, 0.42, 0.2))
	root.add_child(canopy)


func _add_rock_cluster(root: Node3D, scale: float) -> void:
	for i in range(3):
		var rock := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		var r := (0.18 + i * 0.08) * scale
		sphere.radius = r
		sphere.height = r * 1.4
		rock.mesh = sphere
		rock.position = Vector3((i - 1) * 0.22 * scale, r * 0.55, (i % 2) * 0.15 * scale)
		rock.scale = Vector3(1.2, 0.7, 1.0)
		rock.material_override = _cached_prop_mat("rock", Color(0.42, 0.4, 0.36))
		root.add_child(rock)


func _add_creature_prop(root: Node3D, content_type: String, _code: String) -> void:
	var tint := Color(0.75, 0.28, 0.22) if content_type == "monster" else Color(0.55, 0.15, 0.12)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.28
	capsule.height = 0.85
	body.mesh = capsule
	body.position.y = 0.5
	body.material_override = _cached_prop_mat("creature_%s" % content_type, tint)
	root.add_child(body)

	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	head.mesh = sphere
	head.position.y = 1.05
	head.material_override = _cached_prop_mat("creature_head", tint.lightened(0.15))
	root.add_child(head)

	# Ears / horns for silhouette
	for side in [-1.0, 1.0]:
		var horn := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.06
		cone.height = 0.22
		horn.mesh = cone
		horn.position = Vector3(side * 0.16, 1.28, 0.0)
		horn.rotation_degrees = Vector3(0.0, 0.0, side * -25.0)
		horn.material_override = _cached_prop_mat("horn", tint.darkened(0.2))
		root.add_child(horn)


func _add_building_prop(root: Node3D, content_type: String) -> void:
	var base_color := _content_fallback(content_type)
	var base := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.1, 0.7, 1.0)
	base.mesh = box
	base.position.y = 0.35
	base.material_override = _cached_prop_mat("bldg_%s" % content_type, base_color.darkened(0.15))
	root.add_child(base)

	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(1.25, 0.45, 1.1)
	roof.mesh = prism
	roof.position.y = 0.95
	roof.material_override = _cached_prop_mat("roof_%s" % content_type, base_color.lightened(0.1))
	root.add_child(roof)

	var door := MeshInstance3D.new()
	var door_box := BoxMesh.new()
	door_box.size = Vector3(0.28, 0.4, 0.06)
	door.mesh = door_box
	door.position = Vector3(0.0, 0.25, 0.52)
	door.material_override = _cached_prop_mat("door", Color(0.25, 0.16, 0.1))
	root.add_child(door)


func _add_npc_prop(root: Node3D) -> void:
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.22
	capsule.height = 0.9
	body.mesh = capsule
	body.position.y = 0.55
	body.material_override = _cached_prop_mat("npc", Color(0.55, 0.45, 0.75))
	root.add_child(body)

	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.18
	sphere.height = 0.36
	head.mesh = sphere
	head.position.y = 1.15
	head.material_override = _cached_prop_mat("npc_head", Color(0.85, 0.7, 0.58))
	root.add_child(head)


func _add_event_prop(root: Node3D) -> void:
	var crystal := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.45, 1.0, 0.45)
	crystal.mesh = prism
	crystal.position.y = 0.65
	var mat := _cached_prop_mat("event", Color(0.95, 0.5, 0.2))
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.45, 0.15)
	mat.emission_energy_multiplier = 1.2
	crystal.material_override = mat
	root.add_child(crystal)


func _add_generic_prop(root: Node3D, content_type: String) -> void:
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	marker.mesh = sphere
	marker.position.y = 0.45
	marker.material_override = _cached_prop_mat("generic_%s" % content_type, _content_fallback(content_type))
	root.add_child(marker)


func _cached_prop_mat(key: String, color: Color) -> StandardMaterial3D:
	if _prop_mats.has(key):
		return _prop_mats[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.75
	mat.metallic = 0.05
	_prop_mats[key] = mat
	return mat


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
		"workshop":
			return Color(0.55, 0.4, 0.25)
		_:
			return Color(0.5, 0.5, 0.5)


func _add_label(parent: Node3D, text: String, height: float) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 18
	label.outline_size = 6
	label.position = Vector3(0.0, height + 1.55, 0.0)
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


func _skin_height(skin: String) -> float:
	var s := skin.to_lower()
	if "water" in s or "lake" in s:
		return -0.08
	if "mountain" in s or "mine" in s:
		return 0.12
	if "underground" in s:
		return -0.04
	if "interior" in s:
		return 0.02
	return 0.0


func _hash01(a: int, b: int) -> float:
	var n := (a * 73856093) ^ (b * 19349663)
	n = (n << 13) ^ n
	return float((n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff) / 2147483647.0


func _on_tile_input(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int, tile: Dictionary) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		set_selected_tile(tile)
		tile_selected.emit(tile)


func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
