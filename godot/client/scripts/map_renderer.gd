extends Node3D
class_name MapRenderer

const ArtifactsAssets = preload("res://scripts/artifacts_assets.gd")

signal tile_selected(tile: Dictionary)
signal tile_hovered(tile: Dictionary)

@export var tile_size := 2.0
@export var show_labels := false
@export var show_grid_lines := false
@export var ground_thickness := 0.18
@export var seam_overlap := 0.14
@export var height_amp := 0.16
@export var clutter_density := 0.88

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
var _wind_nodes: Array = []
var _wind_phases: Array = []
var _wind_t := 0.0
var _water_meshes: Array = []
var _water_mats: Array = []
var _water_planes: Array = []
var _water_phases: Array = []
var _atmosphere: GPUParticles3D


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
	_shadow_mat.albedo_color = Color(0.02, 0.03, 0.02, 0.42)
	_shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _process(delta: float) -> void:
	_wind_t += delta
	for i in range(_wind_nodes.size()):
		var node: Node3D = _wind_nodes[i]
		if not is_instance_valid(node):
			continue
		var phase: float = _wind_phases[i] if i < _wind_phases.size() else 0.0
		var sway := sin(_wind_t * 1.35 + phase) * 3.2
		var bob := sin(_wind_t * 2.1 + phase * 1.7) * 0.018
		node.rotation_degrees.z = sway
		node.rotation_degrees.x = sway * 0.35
		node.position.y = node.get_meta("base_y", node.position.y) + bob

	# Soft water shimmer: scroll UV offset + gentle emission pulse.
	for i in range(_water_mats.size()):
		var mat: StandardMaterial3D = _water_mats[i]
		if mat == null:
			continue
		var phase := float(i) * 0.7
		mat.uv1_offset = Vector3(
			fmod(_wind_t * 0.035 + phase * 0.01, 1.0),
			fmod(_wind_t * 0.022 + phase * 0.013, 1.0),
			0.0
		)
		mat.emission_energy_multiplier = 0.18 + sin(_wind_t * 0.9 + phase) * 0.06

	for i in range(_water_planes.size()):
		var plane: Node3D = _water_planes[i]
		if not is_instance_valid(plane):
			continue
		var wphase: float = _water_phases[i] if i < _water_phases.size() else 0.0
		plane.position.y = plane.get_meta("base_y", plane.position.y) + sin(_wind_t * 0.85 + wphase) * 0.03


func render_world(maps: Array) -> void:
	_clear_children()
	_tile_nodes.clear()
	_tile_data.clear()
	_prop_mats.clear()
	_wind_nodes.clear()
	_wind_phases.clear()
	_water_meshes.clear()
	_water_mats.clear()
	_water_planes.clear()
	_water_phases.clear()
	_ensure_atmosphere()

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
		_build_continuous_terrain(layer, by_layer[layer])

	for tile in maps:
		if tile is Dictionary:
			_add_tile_pickable(tile)
			var content_type := _content_type(tile)
			if content_type != "terrain" and not content_type.is_empty():
				_add_content_prop(tile, content_type, _content_code(tile))
			elif content_type == "terrain":
				_maybe_add_biome_clutter(tile)

	_add_land_ambience(maps)


func grid_to_world(tile: Dictionary) -> Vector3:
	var x := float(tile.get("x", 0))
	var y := float(tile.get("y", 0))
	var layer := str(tile.get("layer", "overworld"))
	var skin := str(tile.get("skin", "forest_1"))
	return Vector3(x * tile_size, _layer_height(layer) + _surface_height(int(x), int(y), skin), y * tile_size)


func set_selected_tile(tile: Dictionary) -> void:
	_selected_key = _tile_key(tile)
	_refresh_highlights()


func _build_continuous_terrain(layer: String, tiles: Array) -> void:
	if tiles.is_empty():
		return

	var occupancy: Dictionary = {}
	var skin_at: Dictionary = {}
	for tile in tiles:
		var gx := int(tile.get("x", 0))
		var gy := int(tile.get("y", 0))
		var key := "%d,%d" % [gx, gy]
		occupancy[key] = tile
		skin_at[key] = str(tile.get("skin", "forest_1"))

	var by_skin: Dictionary = {}
	for tile in tiles:
		var skin := str(tile.get("skin", "forest_1"))
		if not by_skin.has(skin):
			by_skin[skin] = []
		(by_skin[skin] as Array).append(tile)

	var layer_y := _layer_height(layer)
	for skin in by_skin.keys():
		_add_skin_heightfield(skin, by_skin[skin], layer_y, occupancy, skin_at)

	_add_biome_blend_strips(tiles, layer_y, occupancy, skin_at)
	_add_layer_skirts(tiles, layer_y, occupancy)


func _add_skin_heightfield(skin: String, tiles: Array, layer_y: float, occupancy: Dictionary, skin_at: Dictionary) -> void:
	var is_water := ArtifactsAssets.is_water_skin(skin)
	var mat: StandardMaterial3D
	if is_water:
		mat = ArtifactsAssets.water_material(skin)
	else:
		mat = ArtifactsAssets.tile_material(skin)
		# Keep biome tint from ArtifactsAssets; only ensure filter/vertex color.
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mat.vertex_color_use_as_albedo = true

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half := tile_size * 0.5 + seam_overlap * 0.5
	# 3x3 subdivision softens the chessboard silhouette into rolling ground.
	var subdiv := 3
	for tile in tiles:
		var gx := int(tile.get("x", 0))
		var gy := int(tile.get("y", 0))
		var cx := float(gx) * tile_size
		var cz := float(gy) * tile_size
		_emit_subdivided_patch(st, cx, cz, half, subdiv, layer_y, skin, occupancy, skin_at, is_water)

	st.generate_normals()
	var mesh := st.commit()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Terrain_%s" % skin
	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_terrain_root.add_child(mesh_inst)

	if is_water:
		_water_meshes.append(mesh_inst)
		_water_mats.append(mat)
		_add_water_overlay_planes(skin, tiles, layer_y, occupancy, skin_at)
		_add_water_sparkles(tiles, layer_y, skin)
	else:
		_add_skin_underside(skin, tiles, layer_y)


func _emit_subdivided_patch(
	st: SurfaceTool,
	cx: float,
	cz: float,
	half: float,
	subdiv: int,
	layer_y: float,
	skin: String,
	occupancy: Dictionary,
	skin_at: Dictionary,
	is_water: bool
) -> void:
	var step := (half * 2.0) / float(subdiv)
	for iz in range(subdiv):
		for ix in range(subdiv):
			var x0 := cx - half + float(ix) * step
			var z0 := cz - half + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			var corners := [
				Vector2(x0, z0),
				Vector2(x1, z0),
				Vector2(x1, z1),
				Vector2(x0, z1),
			]
			var heights: Array = []
			for c in corners:
				var h := layer_y + _vertex_height(c.x, c.y, skin, occupancy, skin_at)
				if is_water:
					# Mild ripple so water isn't a flat board.
					h += sin(c.x * 1.7 + c.y * 1.1) * 0.02 + cos(c.x * 0.9 - c.y * 1.3) * 0.015
				heights.append(h)
			_emit_quad(st, corners, heights, skin, occupancy, skin_at, cx, cz, half)


func _emit_quad(
	st: SurfaceTool,
	corners: Array,
	heights: Array,
	skin: String,
	occupancy: Dictionary,
	skin_at: Dictionary,
	patch_cx: float = 0.0,
	patch_cz: float = 0.0,
	patch_half: float = 1.0
) -> void:
	var colors: Array = []
	var uvs: Array = []
	var uv_scale := 0.18
	# Keep signature compatible with subdivided emitter (patch_* unused for world UVs).
	var _keep := patch_cx + patch_cz + patch_half
	for i in range(4):
		colors.append(_blend_color_at(corners[i].x, corners[i].y, skin, occupancy, skin_at))
		# Continuous world UVs; material also uses uv1_scale + triplanar.
		uvs.append(Vector2(corners[i].x * uv_scale, corners[i].y * uv_scale))

	for idx in [0, 1, 2]:
		st.set_uv(uvs[idx])
		st.set_color(colors[idx])
		st.add_vertex(Vector3(corners[idx].x, heights[idx], corners[idx].y))
	for idx in [0, 2, 3]:
		st.set_uv(uvs[idx])
		st.set_color(colors[idx])
		st.add_vertex(Vector3(corners[idx].x, heights[idx], corners[idx].y))


func _add_water_sparkles(tiles: Array, layer_y: float, skin: String) -> void:
	if tiles.is_empty():
		return
	# One particle field per water skin chunk — cheap sparkle / foam flecks.
	var origin := Vector3.ZERO
	var count := 0
	for tile in tiles:
		origin += grid_to_world(tile)
		count += 1
	if count == 0:
		return
	origin /= float(count)
	origin.y = layer_y + _skin_height(skin) + 0.08

	var particles := GPUParticles3D.new()
	particles.name = "WaterSparkles_%s" % skin
	particles.amount = mini(48, maxi(12, count * 2))
	particles.lifetime = 2.8
	particles.preprocess = 1.2
	particles.visibility_aabb = AABB(Vector3(-40, -2, -40), Vector3(80, 6, 80))
	particles.position = origin

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var spread := sqrt(float(count)) * tile_size * 0.55
	mat.emission_box_extents = Vector3(spread, 0.05, spread)
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 180.0
	mat.initial_velocity_min = 0.02
	mat.initial_velocity_max = 0.12
	mat.gravity = Vector3(0, 0.02, 0)
	mat.scale_min = 0.03
	mat.scale_max = 0.08
	mat.color = Color(0.75, 0.9, 1.0, 0.55)
	particles.process_material = mat

	var draw := SphereMesh.new()
	draw.radius = 0.04
	draw.height = 0.08
	var draw_mat := StandardMaterial3D.new()
	draw_mat.albedo_color = Color(0.85, 0.95, 1.0, 0.7)
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.emission_enabled = true
	draw_mat.emission = Color(0.55, 0.75, 0.95)
	draw_mat.emission_energy_multiplier = 1.1
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw.material = draw_mat
	particles.draw_pass_1 = draw
	_terrain_root.add_child(particles)


func _add_land_ambience(maps: Array) -> void:
	# Soft pollen / dust flecks over land so the world feels alive, not a static board.
	var samples: Array = []
	for tile in maps:
		if not (tile is Dictionary):
			continue
		var skin := str(tile.get("skin", "")).to_lower()
		if ArtifactsAssets.is_water_skin(skin) or "interior" in skin or "underground" in skin:
			continue
		var roll := _hash01(int(tile.get("x", 0)) + 3, int(tile.get("y", 0)) + 5)
		if roll > 0.22:
			continue
		samples.append(tile)
		if samples.size() >= 48:
			break
	if samples.is_empty():
		return

	var origin := Vector3.ZERO
	for tile in samples:
		origin += grid_to_world(tile)
	origin /= float(samples.size())
	origin.y += 0.55

	var particles := GPUParticles3D.new()
	particles.name = "LandPollen"
	particles.amount = mini(36, maxi(10, samples.size()))
	particles.lifetime = 4.5
	particles.preprocess = 2.0
	particles.visibility_aabb = AABB(Vector3(-50, -4, -50), Vector3(100, 12, 100))
	particles.position = origin

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var spread := sqrt(float(samples.size())) * tile_size * 1.1
	mat.emission_box_extents = Vector3(maxf(spread, 8.0), 1.2, maxf(spread, 8.0))
	mat.direction = Vector3(0.35, 0.2, 0.15)
	mat.spread = 55.0
	mat.initial_velocity_min = 0.04
	mat.initial_velocity_max = 0.18
	mat.gravity = Vector3(0, -0.015, 0)
	mat.scale_min = 0.02
	mat.scale_max = 0.055
	mat.color = Color(0.85, 0.9, 0.55, 0.45)
	particles.process_material = mat

	var draw := SphereMesh.new()
	draw.radius = 0.03
	draw.height = 0.06
	var draw_mat := StandardMaterial3D.new()
	draw_mat.albedo_color = Color(0.9, 0.92, 0.6, 0.55)
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.emission_enabled = true
	draw_mat.emission = Color(0.7, 0.75, 0.35)
	draw_mat.emission_energy_multiplier = 0.55
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw.material = draw_mat
	particles.draw_pass_1 = draw
	_terrain_root.add_child(particles)


func _add_skin_underside(skin: String, tiles: Array, layer_y: float) -> void:
	# One continuous dirt shelf per skin — avoids per-tile box "board edge" look.
	if tiles.is_empty():
		return
	var color := ArtifactsAssets.skin_base_color(skin).darkened(0.42)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var half := tile_size * 0.5 + seam_overlap * 0.55
	var depth := 0.55
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tile in tiles:
		var gx := int(tile.get("x", 0))
		var gy := int(tile.get("y", 0))
		var cx := float(gx) * tile_size
		var cz := float(gy) * tile_size
		var top_y := layer_y - 0.02
		var bot_y := layer_y - depth
		var x0 := cx - half
		var x1 := cx + half
		var z0 := cz - half
		var z1 := cz + half
		# Bottom face
		st.add_vertex(Vector3(x0, bot_y, z0))
		st.add_vertex(Vector3(x1, bot_y, z0))
		st.add_vertex(Vector3(x1, bot_y, z1))
		st.add_vertex(Vector3(x0, bot_y, z0))
		st.add_vertex(Vector3(x1, bot_y, z1))
		st.add_vertex(Vector3(x0, bot_y, z1))
		var edges := [
			[Vector2(x0, z0), Vector2(x1, z0)],
			[Vector2(x1, z0), Vector2(x1, z1)],
			[Vector2(x1, z1), Vector2(x0, z1)],
			[Vector2(x0, z1), Vector2(x0, z0)],
		]
		for edge in edges:
			var a: Vector2 = edge[0]
			var b: Vector2 = edge[1]
			st.add_vertex(Vector3(a.x, top_y, a.y))
			st.add_vertex(Vector3(b.x, top_y, b.y))
			st.add_vertex(Vector3(b.x, bot_y, b.y))
			st.add_vertex(Vector3(a.x, top_y, a.y))
			st.add_vertex(Vector3(b.x, bot_y, b.y))
			st.add_vertex(Vector3(a.x, bot_y, a.y))
	st.generate_normals()
	var mesh := st.commit()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Underside_%s" % skin
	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_terrain_root.add_child(mesh_inst)


func _add_biome_blend_strips(tiles: Array, layer_y: float, occupancy: Dictionary, skin_at: Dictionary) -> void:
	var seen: Dictionary = {}
	for tile in tiles:
		var gx := int(tile.get("x", 0))
		var gy := int(tile.get("y", 0))
		var skin := str(tile.get("skin", "forest_1"))
		for dir in [Vector2i(1, 0), Vector2i(0, 1)]:
			var nx: int = gx + int(dir.x)
			var ny: int = gy + int(dir.y)
			var nkey := "%d,%d" % [nx, ny]
			if not occupancy.has(nkey):
				continue
			var nskin: String = skin_at[nkey]
			if nskin == skin:
				continue
			var edge_key := "%d,%d>%d,%d" % [mini(gx, nx), mini(gy, ny), maxi(gx, nx), maxi(gy, ny)]
			if seen.has(edge_key):
				continue
			seen[edge_key] = true

			var a_col := ArtifactsAssets.skin_base_color(skin)
			var b_col := ArtifactsAssets.skin_base_color(nskin)
			var mid := a_col.lerp(b_col, 0.5)
			mid.a = 0.55
			var water_edge := ArtifactsAssets.is_water_skin(skin) or ArtifactsAssets.is_water_skin(nskin)
			var mat := StandardMaterial3D.new()
			if water_edge:
				mat.albedo_color = Color(0.82, 0.9, 0.95, 0.42)
				mat.emission_enabled = true
				mat.emission = Color(0.55, 0.75, 0.9)
				mat.emission_energy_multiplier = 0.35
			else:
				mat.albedo_color = mid
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.roughness = 1.0
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED

			var strip := MeshInstance3D.new()
			var box := BoxMesh.new()
			if dir.x != 0:
				box.size = Vector3(seam_overlap * (3.2 if water_edge else 2.2), 0.05 if water_edge else 0.06, tile_size + seam_overlap)
			else:
				box.size = Vector3(tile_size + seam_overlap, 0.05 if water_edge else 0.06, seam_overlap * (3.2 if water_edge else 2.2))
			strip.mesh = box
			strip.material_override = mat
			var mx := (float(gx) + float(nx)) * 0.5 * tile_size
			var mz := (float(gy) + float(ny)) * 0.5 * tile_size
			var hy := layer_y + (_surface_height(gx, gy, skin) + _surface_height(nx, ny, nskin)) * 0.5 + (0.045 if water_edge else 0.03)
			strip.position = Vector3(mx, hy, mz)
			strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_terrain_root.add_child(strip)


func _add_layer_skirts(tiles: Array, layer_y: float, occupancy: Dictionary) -> void:
	var mat_cache: Dictionary = {}
	for tile in tiles:
		var gx := int(tile.get("x", 0))
		var gy := int(tile.get("y", 0))
		var skin := str(tile.get("skin", "forest_1"))
		for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nkey := "%d,%d" % [gx + int(dir.x), gy + int(dir.y)]
			if occupancy.has(nkey):
				continue
			if not mat_cache.has(skin):
				var m := StandardMaterial3D.new()
				m.albedo_color = ArtifactsAssets.skin_base_color(skin).darkened(0.45)
				m.roughness = 1.0
				mat_cache[skin] = m
			var skirt := MeshInstance3D.new()
			var box := BoxMesh.new()
			var wall_h := 0.7
			if dir.x != 0:
				box.size = Vector3(0.12, wall_h, tile_size + seam_overlap)
			else:
				box.size = Vector3(tile_size + seam_overlap, wall_h, 0.12)
			skirt.mesh = box
			skirt.material_override = mat_cache[skin]
			var ox := float(gx) * tile_size + float(int(dir.x)) * (tile_size * 0.5 + seam_overlap * 0.4)
			var oz := float(gy) * tile_size + float(int(dir.y)) * (tile_size * 0.5 + seam_overlap * 0.4)
			skirt.position = Vector3(ox, layer_y - wall_h * 0.25, oz)
			skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_terrain_root.add_child(skirt)


func _vertex_height(wx: float, wz: float, skin: String, occupancy: Dictionary, skin_at: Dictionary) -> float:
	var gx := int(round(wx / tile_size))
	var gy := int(round(wz / tile_size))
	var h := _surface_height(gx, gy, skin)
	var sum := h
	var count := 1.0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var dx: int = int(d.x)
		var dy: int = int(d.y)
		var nkey := "%d,%d" % [gx + dx, gy + dy]
		if occupancy.has(nkey):
			sum += _surface_height(gx + dx, gy + dy, str(skin_at[nkey]))
			count += 1.0
	return sum / count


func _blend_color_at(wx: float, wz: float, skin: String, occupancy: Dictionary, skin_at: Dictionary) -> Color:
	var base := ArtifactsAssets.skin_base_color(skin)
	var gx := int(round(wx / tile_size))
	var gy := int(round(wz / tile_size))
	var mix := base
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nkey := "%d,%d" % [gx + int(d.x), gy + int(d.y)]
		if not occupancy.has(nkey):
			continue
		var nskin: String = skin_at[nkey]
		if nskin == skin:
			continue
		mix = mix.lerp(ArtifactsAssets.skin_base_color(nskin), 0.45)
	# Heavier biome wash so official map skins don't read as board tiles.
	return Color(1, 1, 1, 1).lerp(mix, 0.52)


func _surface_height(gx: int, gy: int, skin: String) -> float:
	var base := _skin_height(skin)
	var n1 := _hash01(gx, gy)
	var n2 := _hash01(gx * 3 + 1, gy * 5 + 2)
	return base + (n1 - 0.5) * height_amp + (n2 - 0.5) * height_amp * 0.45


func _maybe_add_biome_clutter(tile: Dictionary) -> void:
	var skin := str(tile.get("skin", "forest_1")).to_lower()
	if "water" in skin or "lake" in skin or "interior" in skin:
		return
	var roll := _hash01(int(tile.get("x", 0)) + 9, int(tile.get("y", 0)) + 13)
	if roll > clutter_density:
		return
	var root := Node3D.new()
	root.position = grid_to_world(tile) + Vector3(0.0, 0.02, 0.0)
	_props_root.add_child(root)

	if "mountain" in skin or "mine" in skin or "underground" in skin:
		_add_rock_cluster(root, 0.85 + roll * 0.4)
		_add_blob_shadow(root, 0.55)
		return

	var kind := _hash01(int(tile.get("x", 0)), int(tile.get("y", 0)) + 21)
	if kind > 0.58:
		_add_ambient_tree(root, 0.55 + kind * 0.5)
		_add_blob_shadow(root, 0.5)
		if kind > 0.82:
			_add_grass_patch(root, tile)
	elif kind > 0.32:
		_add_bush(root, 0.4 + kind * 0.3)
		_add_blob_shadow(root, 0.35)
		if kind < 0.42:
			_add_grass_patch(root, tile)
	else:
		_add_grass_patch(root, tile)
		_add_blob_shadow(root, 0.28)
		if kind < 0.12:
			_add_rock_cluster(root, 0.35 + kind)


func _add_blob_shadow(root: Node3D, radius: float) -> void:
	var shadow := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.025
	shadow.mesh = disc
	shadow.position.y = 0.015
	shadow.material_override = _shadow_mat
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shadow)


func _add_grass_patch(root: Node3D, tile: Dictionary) -> void:
	var count := 5 + int(_hash01(int(tile.get("x", 0)), int(tile.get("y", 0)) + 7) * 5.0)
	for i in range(count):
		var tuft := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.05 + _hash01(i, int(tile.get("x", 0))) * 0.06
		cone.height = 0.14 + _hash01(i + 1, int(tile.get("y", 0))) * 0.16
		tuft.mesh = cone
		tuft.material_override = _cached_prop_mat("grass", Color(0.2, 0.5, 0.18))
		var ox := (_hash01(i, 11) - 0.5) * tile_size * 0.75
		var oz := (_hash01(i, 17) - 0.5) * tile_size * 0.75
		tuft.position = Vector3(ox, cone.height * 0.5, oz)
		tuft.set_meta("base_y", tuft.position.y)
		root.add_child(tuft)
		_register_wind(tuft)


func _add_bush(root: Node3D, scale: float) -> void:
	var bush := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.28 * scale
	sphere.height = 0.4 * scale
	bush.mesh = sphere
	bush.position.y = 0.18 * scale
	bush.scale = Vector3(1.3, 0.85, 1.1)
	bush.material_override = _cached_prop_mat("bush", Color(0.18, 0.42, 0.2))
	bush.set_meta("base_y", bush.position.y)
	root.add_child(bush)
	_register_wind(bush)

	var leaf2 := bush.duplicate() as MeshInstance3D
	leaf2.position = Vector3(0.12 * scale, 0.22 * scale, -0.08 * scale)
	leaf2.scale = Vector3(0.9, 0.7, 0.95)
	leaf2.set_meta("base_y", leaf2.position.y)
	root.add_child(leaf2)
	_register_wind(leaf2)


func _add_ambient_tree(root: Node3D, scale: float) -> void:
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.06 * scale
	cyl.bottom_radius = 0.1 * scale
	cyl.height = 0.7 * scale
	trunk.mesh = cyl
	trunk.position.y = 0.35 * scale
	trunk.material_override = _cached_prop_mat("trunk_amb", Color(0.32, 0.2, 0.11))
	root.add_child(trunk)

	var foliage := Node3D.new()
	foliage.position.y = 0.75 * scale
	foliage.set_meta("base_y", foliage.position.y)
	root.add_child(foliage)
	_register_wind(foliage)

	for i in range(3):
		var canopy := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.02
		cone.bottom_radius = (0.38 - i * 0.08) * scale
		cone.height = 0.42 * scale
		canopy.mesh = cone
		canopy.position.y = i * 0.28 * scale
		canopy.material_override = _cached_prop_mat("leaf_amb_%d" % i, Color(0.16 + i * 0.04, 0.4 + i * 0.05, 0.18))
		foliage.add_child(canopy)


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
	box_shape.size = Vector3(tile_size * 0.98, maxf(ground_thickness + 0.25, 0.35), tile_size * 0.98)
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
	select_ring.position.y = 0.08
	select_ring.material_override = _select_mat
	select_ring.visible = false
	tile_body.add_child(select_ring)

	var hover_plane := MeshInstance3D.new()
	hover_plane.name = "HoverPlane"
	var plane := BoxMesh.new()
	plane.size = Vector3(tile_size * 0.92, 0.02, tile_size * 0.92)
	hover_plane.mesh = plane
	hover_plane.position.y = 0.05
	hover_plane.material_override = _hover_mat
	hover_plane.visible = false
	tile_body.add_child(hover_plane)

	if show_labels:
		var content_code := _content_code(tile)
		if not content_code.is_empty():
			_add_label(tile_body, content_code, 0.2)


func _add_content_prop(tile: Dictionary, content_type: String, content_code: String) -> void:
	var root := Node3D.new()
	root.name = "Prop_%s_%s" % [content_type, content_code]
	root.position = grid_to_world(tile) + Vector3(0.0, 0.02, 0.0)
	_props_root.add_child(root)

	_add_blob_shadow(root, 0.62)

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

	var tex: Texture2D = ArtifactsAssets.content_texture(content_type, content_code)
	if tex != null:
		var accent := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.5, 0.5)
		accent.mesh = quad
		accent.material_override = ArtifactsAssets.billboard_material(tex, _content_fallback(content_type))
		accent.position = Vector3(0.62, 1.35, 0.62)
		root.add_child(accent)


func _add_tree_prop(root: Node3D, code: String) -> void:
	var scale := 1.05 + _hash01(code.hash(), 3) * 0.35
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.09 * scale
	cyl.bottom_radius = 0.15 * scale
	cyl.height = 1.05 * scale
	trunk.mesh = cyl
	trunk.position.y = 0.52 * scale
	trunk.material_override = _cached_prop_mat("trunk", Color(0.34, 0.21, 0.11))
	root.add_child(trunk)

	var lean := MeshInstance3D.new()
	var lean_mesh := CylinderMesh.new()
	lean_mesh.top_radius = 0.04 * scale
	lean_mesh.bottom_radius = 0.07 * scale
	lean_mesh.height = 0.55 * scale
	lean.mesh = lean_mesh
	lean.position = Vector3(0.12 * scale, 0.85 * scale, -0.05 * scale)
	lean.rotation_degrees = Vector3(12, 20, 18)
	lean.material_override = _cached_prop_mat("trunk2", Color(0.3, 0.18, 0.1))
	root.add_child(lean)

	var foliage := Node3D.new()
	foliage.position.y = 1.15 * scale
	foliage.set_meta("base_y", foliage.position.y)
	root.add_child(foliage)
	_register_wind(foliage)

	for i in range(4):
		var layer := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.02
		cone.bottom_radius = (0.62 - i * 0.1) * scale
		cone.height = 0.55 * scale
		layer.mesh = cone
		layer.position.y = i * 0.32 * scale
		var green := Color(0.14 + i * 0.035, 0.38 + i * 0.04, 0.16 + i * 0.02)
		layer.material_override = _cached_prop_mat("leaf_%d" % i, green)
		foliage.add_child(layer)

	var top := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.28 * scale
	sphere.height = 0.45 * scale
	top.mesh = sphere
	top.position.y = 1.15 * scale
	top.material_override = _cached_prop_mat("canopy", Color(0.17, 0.4, 0.18))
	foliage.add_child(top)


func _add_rock_cluster(root: Node3D, scale: float) -> void:
	for i in range(4):
		var rock := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		var r := (0.16 + i * 0.09) * scale
		sphere.radius = r
		sphere.height = r * (1.2 + (i % 2) * 0.35)
		rock.mesh = sphere
		rock.position = Vector3((i - 1.5) * 0.2 * scale, r * 0.5, ((i % 3) - 1) * 0.16 * scale)
		rock.scale = Vector3(1.25, 0.65 + i * 0.05, 1.05)
		rock.rotation_degrees = Vector3(i * 12.0, i * 35.0, i * 8.0)
		rock.material_override = _cached_prop_mat("rock_%d" % i, Color(0.4 - i * 0.03, 0.38, 0.34))
		root.add_child(rock)


func _add_creature_prop(root: Node3D, content_type: String, _code: String) -> void:
	var tint := Color(0.78, 0.26, 0.2) if content_type == "monster" else Color(0.55, 0.12, 0.1)
	var scale := 1.15 if content_type == "raid" else 1.0

	var hips := MeshInstance3D.new()
	var hips_mesh := SphereMesh.new()
	hips_mesh.radius = 0.26 * scale
	hips_mesh.height = 0.4 * scale
	hips.mesh = hips_mesh
	hips.position.y = 0.35 * scale
	hips.scale = Vector3(1.2, 0.85, 1.0)
	hips.material_override = _cached_prop_mat("creature_hips", tint.darkened(0.1))
	root.add_child(hips)

	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3 * scale
	capsule.height = 0.95 * scale
	body.mesh = capsule
	body.position.y = 0.7 * scale
	body.material_override = _cached_prop_mat("creature_%s" % content_type, tint)
	root.add_child(body)

	for side in [-1.0, 1.0]:
		var shoulder := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.16 * scale
		s.height = 0.28 * scale
		shoulder.mesh = s
		shoulder.position = Vector3(side * 0.28 * scale, 0.95 * scale, 0.0)
		shoulder.material_override = _cached_prop_mat("shoulder", tint.darkened(0.15))
		root.add_child(shoulder)

	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.24 * scale
	sphere.height = 0.48 * scale
	head.mesh = sphere
	head.position.y = 1.25 * scale
	head.material_override = _cached_prop_mat("creature_head", tint.lightened(0.12))
	root.add_child(head)

	for side in [-1.0, 1.0]:
		var horn := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.07 * scale
		cone.height = 0.32 * scale
		horn.mesh = cone
		horn.position = Vector3(side * 0.18 * scale, 1.52 * scale, -0.02)
		horn.rotation_degrees = Vector3(-15.0, 0.0, side * -28.0)
		horn.material_override = _cached_prop_mat("horn", tint.darkened(0.25))
		root.add_child(horn)

	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var e := SphereMesh.new()
		e.radius = 0.045 * scale
		e.height = 0.09 * scale
		eye.mesh = e
		eye.position = Vector3(side * 0.1 * scale, 1.3 * scale, 0.2 * scale)
		var em := _cached_prop_mat("eye", Color(1.0, 0.85, 0.2))
		em.emission_enabled = true
		em.emission = Color(1.0, 0.7, 0.15)
		em.emission_energy_multiplier = 2.0
		eye.material_override = em
		root.add_child(eye)


func _add_building_prop(root: Node3D, content_type: String) -> void:
	var base_color := _content_fallback(content_type)
	var base := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.25, 0.85, 1.1)
	base.mesh = box
	base.position.y = 0.42
	base.material_override = _cached_prop_mat("bldg_%s" % content_type, base_color.darkened(0.12))
	root.add_child(base)

	var wing := MeshInstance3D.new()
	var wing_box := BoxMesh.new()
	wing_box.size = Vector3(0.55, 0.55, 0.7)
	wing.mesh = wing_box
	wing.position = Vector3(0.7, 0.28, 0.1)
	wing.material_override = _cached_prop_mat("bldg_wing_%s" % content_type, base_color.darkened(0.2))
	root.add_child(wing)

	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(1.45, 0.55, 1.2)
	roof.mesh = prism
	roof.position.y = 1.1
	roof.material_override = _cached_prop_mat("roof_%s" % content_type, base_color.lightened(0.08).darkened(0.05))
	root.add_child(roof)

	var chimney := MeshInstance3D.new()
	var chim := BoxMesh.new()
	chim.size = Vector3(0.18, 0.4, 0.18)
	chimney.mesh = chim
	chimney.position = Vector3(-0.35, 1.35, -0.25)
	chimney.material_override = _cached_prop_mat("chimney", Color(0.35, 0.28, 0.24))
	root.add_child(chimney)

	var door := MeshInstance3D.new()
	var door_box := BoxMesh.new()
	door_box.size = Vector3(0.32, 0.48, 0.06)
	door.mesh = door_box
	door.position = Vector3(0.0, 0.28, 0.58)
	door.material_override = _cached_prop_mat("door", Color(0.22, 0.14, 0.08))
	root.add_child(door)

	var window := MeshInstance3D.new()
	var win := BoxMesh.new()
	win.size = Vector3(0.22, 0.18, 0.04)
	window.mesh = win
	window.position = Vector3(0.35, 0.55, 0.58)
	var wmat := _cached_prop_mat("window", Color(0.95, 0.85, 0.45))
	wmat.emission_enabled = true
	wmat.emission = Color(0.95, 0.8, 0.35)
	wmat.emission_energy_multiplier = 0.9
	window.material_override = wmat
	root.add_child(window)

	if content_type == "bank" or content_type == "grand_exchange":
		base.material_override = _emissive_building_mat(content_type, base_color)
		roof.material_override = _emissive_building_mat("%s_roof" % content_type, base_color.lightened(0.06))
		var lantern := MeshInstance3D.new()
		var lamp := SphereMesh.new()
		lamp.radius = 0.1
		lamp.height = 0.18
		lantern.mesh = lamp
		lantern.position = Vector3(-0.35, 0.72, 0.58)
		var lmat := _cached_prop_mat("lantern_%s" % content_type, Color(1.0, 0.85, 0.45))
		lmat.emission_enabled = true
		if content_type == "grand_exchange":
			lmat.emission = Color(1.0, 0.78, 0.25)
			lmat.emission_energy_multiplier = 1.35
		else:
			lmat.emission = Color(0.35, 0.55, 1.0)
			lmat.emission_energy_multiplier = 1.1
		lantern.material_override = lmat
		root.add_child(lantern)


func _add_npc_prop(root: Node3D) -> void:
	var robe := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.12
	cone.bottom_radius = 0.32
	cone.height = 0.85
	robe.mesh = cone
	robe.position.y = 0.45
	robe.material_override = _cached_prop_mat("npc_robe", Color(0.45, 0.35, 0.7))
	root.add_child(robe)

	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.2
	capsule.height = 0.7
	body.mesh = capsule
	body.position.y = 0.75
	body.material_override = _cached_prop_mat("npc", Color(0.55, 0.45, 0.78))
	root.add_child(body)

	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.17
	sphere.height = 0.34
	head.mesh = sphere
	head.position.y = 1.25
	head.material_override = _cached_prop_mat("npc_head", Color(0.88, 0.72, 0.58))
	root.add_child(head)

	var hat := MeshInstance3D.new()
	var hat_mesh := CylinderMesh.new()
	hat_mesh.top_radius = 0.0
	hat_mesh.bottom_radius = 0.22
	hat_mesh.height = 0.35
	hat.mesh = hat_mesh
	hat.position.y = 1.5
	hat.material_override = _cached_prop_mat("npc_hat", Color(0.35, 0.25, 0.55))
	root.add_child(hat)


func _add_event_prop(root: Node3D) -> void:
	var crystal := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.5, 1.15, 0.5)
	crystal.mesh = prism
	crystal.position.y = 0.7
	var mat := _cached_prop_mat("event", Color(0.95, 0.5, 0.2))
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.45, 0.15)
	mat.emission_energy_multiplier = 1.4
	crystal.material_override = mat
	crystal.set_meta("base_y", crystal.position.y)
	root.add_child(crystal)
	_register_wind(crystal)

	var orbit := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.35
	ring.outer_radius = 0.42
	orbit.mesh = ring
	orbit.position.y = 0.7
	orbit.rotation_degrees = Vector3(70, 0, 20)
	orbit.material_override = mat
	root.add_child(orbit)


func _add_generic_prop(root: Node3D, content_type: String) -> void:
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.38
	sphere.height = 0.76
	marker.mesh = sphere
	marker.position.y = 0.48
	marker.material_override = _cached_prop_mat("generic_%s" % content_type, _content_fallback(content_type))
	root.add_child(marker)


func _register_wind(node: Node3D) -> void:
	if not node.has_meta("base_y"):
		node.set_meta("base_y", node.position.y)
	_wind_nodes.append(node)
	_wind_phases.append(_hash01(_wind_nodes.size() * 17, 29) * TAU)


func _cached_prop_mat(key: String, color: Color) -> StandardMaterial3D:
	if _prop_mats.has(key):
		return _prop_mats[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var h := _hash01(key.hash(), 41)
	mat.roughness = clampf(0.55 + h * 0.38, 0.45, 0.95)
	mat.metallic = 0.03 + h * 0.05
	_prop_mats[key] = mat
	return mat


func _emissive_building_mat(key: String, color: Color) -> StandardMaterial3D:
	var cache_key := "emit_%s" % key
	if _prop_mats.has(cache_key):
		return _prop_mats[cache_key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.darkened(0.08)
	mat.roughness = 0.48 if "grand_exchange" in key else 0.62
	mat.metallic = 0.12 if "grand_exchange" in key else 0.08
	mat.emission_enabled = true
	if "grand_exchange" in key:
		mat.emission = Color(0.95, 0.72, 0.2)
		mat.emission_energy_multiplier = 0.45
	else:
		mat.emission = Color(0.25, 0.4, 0.75)
		mat.emission_energy_multiplier = 0.32
	_prop_mats[cache_key] = mat
	return mat


func _add_water_overlay_planes(skin: String, tiles: Array, layer_y: float, occupancy: Dictionary, skin_at: Dictionary) -> void:
	var mat := ArtifactsAssets.water_material(skin)
	var half := tile_size * 0.5 + seam_overlap * 0.25
	for tile in tiles:
		var gx := int(tile.get("x", 0))
		var gy := int(tile.get("y", 0))
		var plane := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(half * 2.0, half * 2.0)
		plane.mesh = mesh
		plane.material_override = mat
		var hy := layer_y + _vertex_height(float(gx) * tile_size, float(gy) * tile_size, skin, occupancy, skin_at) + 0.05
		plane.position = Vector3(float(gx) * tile_size, hy, float(gy) * tile_size)
		plane.set_meta("base_y", hy)
		plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_terrain_root.add_child(plane)
		_water_planes.append(plane)
		_water_phases.append(_hash01(gx * 13 + 3, gy * 17 + 5) * TAU)


func _ensure_atmosphere() -> void:
	if _atmosphere != null and is_instance_valid(_atmosphere):
		return
	_atmosphere = GPUParticles3D.new()
	_atmosphere.name = "AtmosphereDust"
	_atmosphere.amount = 56
	_atmosphere.lifetime = 8.0
	_atmosphere.preprocess = 2.5
	_atmosphere.explosiveness = 0.0
	_atmosphere.randomness = 0.75
	_atmosphere.visibility_aabb = AABB(Vector3(-48, -10, -48), Vector3(96, 32, 96))
	_atmosphere.local_coords = false

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(30, 9, 30)
	mat.direction = Vector3(0.4, 0.12, 0.25)
	mat.spread = 32.0
	mat.initial_velocity_min = 0.12
	mat.initial_velocity_max = 0.5
	mat.gravity = Vector3(0, -0.035, 0)
	mat.damping_min = 0.04
	mat.damping_max = 0.18
	mat.scale_min = 0.035
	mat.scale_max = 0.11
	mat.color = Color(0.8, 0.76, 0.58, 0.5)
	_atmosphere.process_material = mat

	var draw := QuadMesh.new()
	draw.size = Vector2(0.11, 0.11)
	var draw_mat := StandardMaterial3D.new()
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.albedo_color = Color(0.84, 0.78, 0.6, 0.42)
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	draw_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	draw.material = draw_mat
	_atmosphere.draw_pass_1 = draw
	add_child(_atmosphere)


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
		return -0.1
	if "mountain" in s or "mine" in s:
		return 0.16
	if "underground" in s:
		return -0.05
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
		if child == _atmosphere:
			continue
		child.queue_free()
