extends RefCounted
class_name ArtifactsAssets

const MAP_BASE := "https://artifactsmmo.com/images/maps/%s.png"
const MONSTER_BASE := "https://artifactsmmo.com/images/monsters/%s.png"
const RESOURCE_BASE := "https://artifactsmmo.com/images/resources/%s.png"
const NPC_BASE := "https://artifactsmmo.com/images/npcs/%s.png"
const CHARACTER_BASE := "https://artifactsmmo.com/images/characters/%s.png"
const ITEM_BASE := "https://artifactsmmo.com/images/items/%s.png"

static var _textures: Dictionary = {}
static var _pending: Dictionary = {}
static var _materials: Dictionary = {}
static var _watchers: Dictionary = {} # cache_key -> Array[StandardMaterial3D]


static func map_texture(skin: String) -> Texture2D:
	var key := skin if not skin.is_empty() else "forest_1"
	return _request(MAP_BASE % key, "map:%s" % key, Color(0.22, 0.45, 0.24))


static func content_texture(content_type: String, content_code: String) -> Texture2D:
	var code := content_code if not content_code.is_empty() else content_type
	match content_type:
		"monster", "raid":
			return _request(MONSTER_BASE % code, "monster:%s" % code, Color(0.75, 0.25, 0.2))
		"resource":
			return _request(RESOURCE_BASE % code, "resource:%s" % code, Color(0.25, 0.55, 0.3))
		"npc", "tasks_master":
			return _request(NPC_BASE % code, "npc:%s" % code, Color(0.55, 0.45, 0.75))
		"bank":
			return _request(ITEM_BASE % "bag", "item:bag", Color(0.3, 0.45, 0.85))
		"grand_exchange":
			return _request(ITEM_BASE % "gold_coin", "item:gold", Color(0.9, 0.75, 0.2))
		"workshop":
			return _request(ITEM_BASE % "wooden_stick", "item:workshop", Color(0.55, 0.4, 0.25))
		"event":
			return _request(ITEM_BASE % "jasper_crystal", "item:event", Color(0.95, 0.5, 0.2))
		_:
			return null


static func character_texture(skin: String) -> Texture2D:
	var key := skin if not skin.is_empty() else "men1"
	return _request(CHARACTER_BASE % key, "char:%s" % key, Color(0.2, 0.75, 0.85))


static func tile_material(skin: String) -> StandardMaterial3D:
	var skin_key := skin if not skin.is_empty() else "forest_1"
	var key := "tilemat:%s" % skin_key
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.uv1_scale = Vector3(1, 1, 1)
	var tex := map_texture(skin_key)
	if tex != null:
		mat.albedo_texture = tex
		_watch(tex, mat)
	else:
		mat.albedo_color = _skin_fallback_color(skin_key)
	_materials[key] = mat
	return mat


static func billboard_material(tex: Texture2D, fallback: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.15
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex != null:
		mat.albedo_texture = tex
		mat.albedo_color = Color(1, 1, 1, 1)
		_watch(tex, mat)
	else:
		mat.albedo_color = fallback
	return mat


static func _watch(placeholder_or_tex: Texture2D, mat: StandardMaterial3D) -> void:
	for cache_key in _pending.keys():
		if _textures.get(cache_key) == placeholder_or_tex:
			if not _watchers.has(cache_key):
				_watchers[cache_key] = []
			(_watchers[cache_key] as Array).append(mat)
			return


static func _skin_fallback_color(skin: String) -> Color:
	var s := skin.to_lower()
	if "water" in s or "lake" in s:
		return Color(0.2, 0.45, 0.7)
	if "mountain" in s or "mine" in s or "underground" in s:
		return Color(0.35, 0.34, 0.32)
	if "interior" in s:
		return Color(0.45, 0.38, 0.3)
	if "bank" in s:
		return Color(0.32, 0.4, 0.55)
	return Color(0.25, 0.48, 0.28)


static func _request(url: String, cache_key: String, fallback_color: Color) -> Texture2D:
	if _textures.has(cache_key) and not _pending.has(cache_key):
		return _textures[cache_key]
	if _pending.has(cache_key):
		return _textures.get(cache_key, null)

	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(fallback_color)
	var placeholder := ImageTexture.create_from_image(img)
	_textures[cache_key] = placeholder
	_pending[cache_key] = true

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return placeholder

	tree.create_timer(0.0).timeout.connect(
		func() -> void:
			_begin_http(url, cache_key, placeholder)
	)
	return placeholder


static func _begin_http(url: String, cache_key: String, placeholder: Texture2D) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		_pending.erase(cache_key)
		return
	var http := HTTPRequest.new()
	tree.root.add_child(http)
	http.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			_pending.erase(cache_key)
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
				return
			var loaded := Image.new()
			var err := loaded.load_png_from_buffer(body)
			if err != OK:
				return
			var tex := ImageTexture.create_from_image(loaded)
			_textures[cache_key] = tex
			if _watchers.has(cache_key):
				for mat in _watchers[cache_key]:
					if mat is StandardMaterial3D:
						(mat as StandardMaterial3D).albedo_texture = tex
						(mat as StandardMaterial3D).albedo_color = Color(1, 1, 1, 1)
				_watchers.erase(cache_key)
			for mat_key in _materials.keys():
				var mat: StandardMaterial3D = _materials[mat_key]
				if mat.albedo_texture == placeholder:
					mat.albedo_texture = tex
	)
	var err := http.request(url)
	if err != OK:
		_pending.erase(cache_key)
		http.queue_free()
